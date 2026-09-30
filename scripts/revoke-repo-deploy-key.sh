#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage:"
  echo "  CONFIRM_REVOKE=argocd-repo-<environment> $0 <environment>"
  exit 1
fi

if ! [[ "$ENVIRONMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#ENVIRONMENT} > 40 )); then
  echo "ERROR: environment must be DNS-safe and <= 40 characters"
  exit 1
fi

for TOOL in gh jq git ssh-keygen; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $TOOL"
    exit 1
  fi
done

REPO_ROOT="$(
  git rev-parse --show-toplevel 2>/dev/null
)" || {
  echo "ERROR: run this script from inside the repository"
  exit 1
}

KEY_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/kubernetes-gitops-platform/keys"
KEY_FILE="${KEY_ROOT}/${ENVIRONMENT}/argocd-repo"
PUBLIC_KEY_FILE="${KEY_FILE}.pub"

TITLE="argocd-repo-${ENVIRONMENT}"
EXPECTED_CONFIRMATION="$TITLE"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-kubernetes-gitops-dev}"

if [[ ! -r "$PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: local public key is required for safe identity verification:"
  echo "  $PUBLIC_KEY_FILE"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI is not authenticated"
  exit 1
fi

cd "$REPO_ROOT"

REPO_SLUG="$(
  gh repo view \
    --json nameWithOwner \
    --jq '.nameWithOwner'
)"

if [[ -z "$REPO_SLUG" || "$REPO_SLUG" != */* ]]; then
  echo "ERROR: could not determine GitHub repository"
  exit 1
fi

LOCAL_IDENTITY="$(
  awk 'NR == 1 {print $1 " " $2}' "$PUBLIC_KEY_FILE"
)"

KEYS_JSON="$(
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/${REPO_SLUG}/keys?per_page=100"
)"

REGISTERED_KEY="$(
  jq \
    --arg title "$TITLE" \
    '[.[] | select(.title == $title)][0] // empty' \
    <<<"$KEYS_JSON"
)"

if [[ -z "$REGISTERED_KEY" ]]; then
  echo "PASS: deploy key is already absent from GitHub"
  echo "Title: $TITLE"
  exit 0
fi

REMOTE_IDENTITY="$(
  jq -r '.key // ""' <<<"$REGISTERED_KEY" \
  | awk '{print $1 " " $2}'
)"

if [[ "$REMOTE_IDENTITY" != "$LOCAL_IDENTITY" ]]; then
  echo "ERROR: deploy key title exists but cryptographic identity differs"
  echo "Refusing to delete an unexpected credential"
  exit 1
fi

KEY_ID="$(
  jq -r '.id' <<<"$REGISTERED_KEY"
)"

READ_ONLY="$(
  jq -r '.read_only' <<<"$REGISTERED_KEY"
)"

VERIFIED="$(
  jq -r '.verified' <<<"$REGISTERED_KEY"
)"

echo "===== DEPLOY KEY REVOCATION ====="
echo
echo "Repository  : $REPO_SLUG"
echo "Environment : $ENVIRONMENT"
echo "Title       : $TITLE"
echo "GitHub ID   : $KEY_ID"
echo "Read only   : $READ_ONLY"
echo "Verified    : $VERIFIED"
echo
echo "Fingerprint:"
ssh-keygen -lf "$PUBLIC_KEY_FILE"

#
# A credential created by configure-repo-auth.sh uses this same
# environment-specific Secret name. Refuse obvious active use.
#
# Always inspect the explicitly selected Kubernetes context instead of
# relying on whichever context happens to be current.
#
if command -v kubectl >/dev/null 2>&1; then
  if kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1; then
    if kubectl --context "$KUBE_CONTEXT" \
        get namespace argocd >/dev/null 2>&1; then

      if kubectl --context "$KUBE_CONTEXT" \
          get secret "$TITLE" \
          -n argocd >/dev/null 2>&1; then

        echo
        echo "ERROR: an Argo CD repository Secret exists for this environment:"
        echo "  $TITLE"
        echo "Context:"
        echo "  $KUBE_CONTEXT"
        echo
        echo "Refusing to revoke a credential that may still be active."
        exit 1
      fi
    fi
  else
    echo "WARN: Kubernetes context not found; active-use check skipped:"
    echo "  $KUBE_CONTEXT"
  fi
fi

if [[ "${CONFIRM_REVOKE:-}" != "$EXPECTED_CONFIRMATION" ]]; then
  echo
  echo "ERROR: explicit revocation confirmation is required"
  echo
  echo "Run:"
  echo "  CONFIRM_REVOKE=$EXPECTED_CONFIRMATION \\"
  echo "    $0 $ENVIRONMENT"
  exit 1
fi

echo
echo "===== REVOKE FROM GITHUB ====="

gh api \
  --method DELETE \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "repos/${REPO_SLUG}/keys/${KEY_ID}"

echo "PASS: GitHub accepted deploy key revocation"

echo
echo "===== VERIFY REVOCATION ====="

REMAINING="$(
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/${REPO_SLUG}/keys?per_page=100" \
  | jq \
      --arg id "$KEY_ID" '
        [
          .[]
          | select((.id | tostring) == $id)
        ]
        | length
      '
)"

if [[ "$REMAINING" -ne 0 ]]; then
  echo "ERROR: deploy key still appears in GitHub"
  exit 1
fi

echo "PASS: deploy key is no longer registered"

echo
echo "NOTE:"
echo "- Local private/public key files were NOT deleted."
echo "- Remove local credentials separately after confirming they are no longer needed."
