#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-}"
EXPECTED_CONTEXT="${KUBE_CONTEXT:-kind-kubernetes-gitops-dev}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage:"
  echo "  ARGO_REPO_SSH_KEY_FILE=/path/to/private-key $0 <environment>"
  exit 1
fi

if ! [[ "$ENVIRONMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
   (( ${#ENVIRONMENT} > 40 )); then
  echo "ERROR: environment must be DNS-safe and <= 40 characters"
  exit 1
fi

if [[ -z "${ARGO_REPO_SSH_KEY_FILE:-}" ]]; then
  echo "ERROR: ARGO_REPO_SSH_KEY_FILE must be explicitly assigned"
  echo
  echo "Example:"
  echo "  export ARGO_REPO_SSH_KEY_FILE=\$HOME/.config/kubernetes-gitops-platform/keys/${ENVIRONMENT}/argocd-repo"
  exit 1
fi

for TOOL in git jq kubectl realpath ssh-keygen stat; do
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

KEY_FILE="$(
  realpath -e -- "$ARGO_REPO_SSH_KEY_FILE" 2>/dev/null
)" || {
  echo "ERROR: assigned private key does not exist"
  exit 1
}

if [[ ! -f "$KEY_FILE" || ! -r "$KEY_FILE" ]]; then
  echo "ERROR: assigned private key is not a readable regular file"
  exit 1
fi

#
# Never permit credential material from inside the source repository.
#
case "$KEY_FILE" in
  "$REPO_ROOT"/*)
    echo "ERROR: refusing to use a private key stored inside the Git repository"
    exit 1
    ;;
esac

#
# Private key may be read/write or read-only by its owner,
# but never accessible by group or others.
#
KEY_MODE="$(stat -c '%a' "$KEY_FILE")"

if ! [[ "$KEY_MODE" =~ ^[46]00$ ]]; then
  echo "ERROR: insecure private-key permissions: $KEY_MODE"
  echo "Expected 600 or 400"
  exit 1
fi

#
# Ensure the private key is valid without printing its contents.
#
DERIVED_PUBLIC="$(
  ssh-keygen -y -f "$KEY_FILE" 2>/dev/null
)" || {
  echo "ERROR: assigned file is not a usable SSH private key"
  exit 1
}

PUBLIC_KEY_FILE="${KEY_FILE}.pub"

if [[ ! -r "$PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: matching public key file is required:"
  echo "  $PUBLIC_KEY_FILE"
  exit 1
fi

DERIVED_IDENTITY="$(
  awk '{print $1 " " $2}' <<<"$DERIVED_PUBLIC"
)"

PUBLIC_IDENTITY="$(
  awk 'NR == 1 {print $1 " " $2}' "$PUBLIC_KEY_FILE"
)"

if [[ "$DERIVED_IDENTITY" != "$PUBLIC_IDENTITY" ]]; then
  echo "ERROR: private key does not match its .pub file"
  exit 1
fi

#
# Discover the GitOps SSH repository from version-controlled manifests.
# Exactly one repository is allowed for this bootstrap.
#
mapfile -t REPO_URLS < <(
  grep -RhoE \
    'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git' \
    "$REPO_ROOT/gitops" \
  | sort -u
)

if [[ "${#REPO_URLS[@]}" -ne 1 ]]; then
  echo "ERROR: expected exactly one GitHub SSH repository in gitops manifests"
  echo "Found: ${#REPO_URLS[@]}"
  exit 1
fi

REPO_URL="${REPO_URLS[0]}"
REPO_SLUG="${REPO_URL#git@github.com:}"
REPO_SLUG="${REPO_SLUG%.git}"

SECRET_NAME="argocd-repo-${ENVIRONMENT}"

echo "===== ARGO CD REPOSITORY AUTH PREFLIGHT ====="
echo
echo "Environment : $ENVIRONMENT"
echo "Repository  : $REPO_URL"
echo "Secret name : $SECRET_NAME"
echo "Context     : $EXPECTED_CONTEXT"
echo "Key file    : $KEY_FILE"
echo
echo "Fingerprint:"
ssh-keygen -lf "$PUBLIC_KEY_FILE"

#
# Wrong-cluster protection.
#
CURRENT_CONTEXT="$(
  kubectl config current-context 2>/dev/null
)" || {
  echo "ERROR: kubectl has no current context"
  exit 1
}

if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo
  echo "ERROR: refusing to modify unexpected Kubernetes context"
  echo "Current : $CURRENT_CONTEXT"
  echo "Expected: $EXPECTED_CONTEXT"
  exit 1
fi

echo
echo "PASS: Kubernetes context verified"

if ! kubectl get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Argo CD namespace does not exist: $ARGO_NAMESPACE"
  exit 1
fi

echo "PASS: Argo CD namespace exists"

#
# Do not dynamically trust whatever ssh-keyscan returns.
# Argo CD's managed known-hosts configuration must already trust github.com.
#
KNOWN_HOSTS="$(
  kubectl get configmap argocd-ssh-known-hosts-cm \
    -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.data.ssh_known_hosts}' \
    2>/dev/null
)" || {
  echo "ERROR: Argo CD SSH known-hosts ConfigMap not found"
  exit 1
}

if grep -Eq \
  '(^|[[:space:]])github\.com([,[:space:]]|$)' \
  <<<"$KNOWN_HOSTS"; then
  echo "PASS: github.com exists in Argo CD trusted SSH hosts"
else
  echo "ERROR: github.com is not present in Argo CD trusted SSH hosts"
  exit 1
fi

#
# If GitHub CLI authentication is available, verify that the supplied
# public key has actually been assigned to this repository and is read-only.
#
if command -v gh >/dev/null 2>&1 &&
   gh auth status >/dev/null 2>&1; then

  PUBLIC_KEY_IDENTITY="$(
    awk 'NR == 1 {print $1 " " $2}' "$PUBLIC_KEY_FILE"
  )"

  EXPECTED_DEPLOY_KEY_TITLE="argocd-repo-${ENVIRONMENT}"

  REGISTERED_KEY="$(
    gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2026-03-10" \
      "repos/${REPO_SLUG}/keys?per_page=100" \
    | jq \
        --arg title "$EXPECTED_DEPLOY_KEY_TITLE" \
        '[.[] | select(.title == $title)][0] // empty'
  )"

  if [[ -z "$REGISTERED_KEY" ]]; then
    echo "ERROR: expected deploy key is not registered on repository:"
    echo "  $REPO_SLUG"
    echo
    echo "Expected title:"
    echo "  $EXPECTED_DEPLOY_KEY_TITLE"
    exit 1
  fi

  REMOTE_KEY_IDENTITY="$(
    jq -r '.key // ""' <<<"$REGISTERED_KEY" \
    | awk '{print $1 " " $2}'
  )"

  if [[ "$REMOTE_KEY_IDENTITY" != "$PUBLIC_KEY_IDENTITY" ]]; then
    echo "ERROR: GitHub deploy key title exists but key material does not match"
    echo "Refusing to use a different credential for this environment"
    exit 1
  fi

  READ_ONLY="$(
    jq -r '.read_only' <<<"$REGISTERED_KEY"
  )"

  VERIFIED="$(
    jq -r '.verified' <<<"$REGISTERED_KEY"
  )"

  KEY_ID="$(
    jq -r '.id' <<<"$REGISTERED_KEY"
  )"

  if [[ "$READ_ONLY" != "true" ]]; then
    echo "ERROR: registered deploy key has write access"
    echo "Refusing to use it for Argo CD"
    exit 1
  fi

  if [[ "$VERIFIED" != "true" ]]; then
    echo "ERROR: GitHub deploy key is not verified"
    exit 1
  fi

  echo "PASS: GitHub deploy key identity matches environment"
  echo "PASS: GitHub deploy key is registered, verified, and read-only"
  echo "GitHub key ID: $KEY_ID"
else
  echo "WARN: GitHub CLI verification unavailable"
  echo "      Ensure the public key was manually registered as a read-only deploy key"
fi

#
# Never replace another repository credential.
#
EXISTING_REPO_SECRETS="$(
  kubectl get secrets \
    -n "$ARGO_NAMESPACE" \
    -l argocd.argoproj.io/secret-type=repository \
    -o json \
  | jq -r \
      --arg repo "$REPO_URL" '
        .items[]
        | select(
            ((.data.url // "") | @base64d) == $repo
          )
        | .metadata.name
      '
)"

if [[ -n "$EXISTING_REPO_SECRETS" ]]; then
  echo
  echo "ERROR: repository authentication already exists for:"
  echo "  $REPO_URL"
  echo
  echo "Existing Secret(s):"
  printf '  %s\n' $EXISTING_REPO_SECRETS
  echo
  echo "Refusing to replace or reuse existing Argo CD credentials."
  exit 1
fi

if kubectl get secret "$SECRET_NAME" \
  -n "$ARGO_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Secret name already exists:"
  echo "  $SECRET_NAME"
  exit 1
fi

echo
echo "===== CREATE ARGO CD REPOSITORY SECRET ====="

#
# The private key is streamed directly into Kubernetes.
# It is never written into a generated manifest on disk.
#
kubectl create secret generic "$SECRET_NAME" \
  -n "$ARGO_NAMESPACE" \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-file=sshPrivateKey="$KEY_FILE" \
  --dry-run=client \
  -o json \
| jq '
    .metadata.labels["argocd.argoproj.io/secret-type"] = "repository"
  ' \
| kubectl create -f -

echo
echo "===== VERIFY SECRET METADATA ====="

kubectl get secret "$SECRET_NAME" \
  -n "$ARGO_NAMESPACE" \
  -o json \
| jq '{
    name: .metadata.name,
    repositorySecretType:
      .metadata.labels["argocd.argoproj.io/secret-type"],
    dataKeys: (.data | keys)
  }'

echo
echo "PASS: unique Argo CD repository authentication configured"
echo
echo "SECURITY:"
echo "- No private key was printed."
echo "- No credential was written into Git."
echo "- Existing repository credentials were not replaced."
echo "- GitHub deploy key is read-only."
