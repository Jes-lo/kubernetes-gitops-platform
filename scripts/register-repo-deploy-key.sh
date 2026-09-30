#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $0 <environment>"
  echo "Example: $0 dev-rebuild"
  exit 1
fi

if ! [[ "$ENVIRONMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#ENVIRONMENT} > 40 )); then
  echo "ERROR: environment must be DNS-safe:"
  echo "  - lowercase a-z"
  echo "  - numbers 0-9"
  echo "  - hyphens only"
  echo "  - must start and end with a letter or number"
  echo "  - maximum 40 characters"
  exit 1
fi

for TOOL in gh jq git; do
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

if [[ ! -r "$PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: public key not found:"
  echo "  $PUBLIC_KEY_FILE"
  echo
  echo "Generate it first with:"
  echo "  ./scripts/generate-repo-deploy-key.sh $ENVIRONMENT"
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

TITLE="argocd-repo-${ENVIRONMENT}"
PUBLIC_KEY="$(cat "$PUBLIC_KEY_FILE")"

# SSH comments are metadata, not part of the cryptographic identity.
# Compare only key type + base64 key material.
PUBLIC_KEY_IDENTITY="$(
  awk 'NR == 1 {print $1 " " $2}' "$PUBLIC_KEY_FILE"
)"

echo "===== DEPLOY KEY REGISTRATION ====="
echo
echo "Repository  : $REPO_SLUG"
echo "Environment : $ENVIRONMENT"
echo "Title       : $TITLE"
echo "Mode        : READ-ONLY"
echo
echo "Fingerprint:"
ssh-keygen -lf "$PUBLIC_KEY_FILE"

KEYS_JSON="$(
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/${REPO_SLUG}/keys?per_page=100"
)"

EXACT_KEY="$(
  jq \
    --arg key "$PUBLIC_KEY" \
    '[.[] | select(.key == $key)][0] // empty' \
    <<<"$KEYS_JSON"
)"

if [[ -n "$EXACT_KEY" ]]; then
  EXISTING_READ_ONLY="$(
    jq -r '.read_only' <<<"$EXACT_KEY"
  )"

  if [[ "$EXISTING_READ_ONLY" == "true" ]]; then
    echo
    echo "PASS: this public key is already registered as read-only"
    exit 0
  fi

  echo "ERROR: this public key already exists with write access"
  echo "Refusing to continue"
  exit 1
fi

TITLE_CONFLICT="$(
  jq \
    --arg title "$TITLE" \
    '[.[] | select(.title == $title)][0] // empty' \
    <<<"$KEYS_JSON"
)"

if [[ -n "$TITLE_CONFLICT" ]]; then
  echo "ERROR: a different deploy key already uses title:"
  echo "  $TITLE"
  echo
  echo "Use a different environment name."
  exit 1
fi

RESULT="$(
  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/${REPO_SLUG}/keys" \
    -f "title=$TITLE" \
    -f "key=$PUBLIC_KEY" \
    -F "read_only=true"
)"

KEY_ID="$(jq -r '.id' <<<"$RESULT")"
READ_ONLY="$(jq -r '.read_only' <<<"$RESULT")"
VERIFIED="$(jq -r '.verified' <<<"$RESULT")"

if [[ "$READ_ONLY" != "true" ]]; then
  echo "ERROR: GitHub did not create the deploy key as read-only"
  exit 1
fi

echo
echo "PASS: deploy key registered successfully"
echo "GitHub key ID : $KEY_ID"
echo "Read only     : $READ_ONLY"
echo "Verified      : $VERIFIED"
echo
echo "SECURITY:"
echo "- Only the public key was sent to GitHub."
echo "- The private key remains outside the repository."
echo "- No existing Argo CD credential was modified."
