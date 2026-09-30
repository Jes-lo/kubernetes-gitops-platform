#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $0 <environment>"
  echo "Example: $0 dev"
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

for TOOL in ssh-keygen git; do
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

REMOTE_URL="$(
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true
)"

KEY_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/kubernetes-gitops-platform/keys"
KEY_DIR="${KEY_ROOT}/${ENVIRONMENT}"
KEY_FILE="${KEY_DIR}/argocd-repo"

# Defense in depth: generated private material must never live under the repo.
case "$KEY_DIR/" in
  "$REPO_ROOT"/*)
    echo "ERROR: refusing to generate credentials inside the Git repository"
    exit 1
    ;;
esac

if [[ -e "$KEY_FILE" || -e "${KEY_FILE}.pub" ]]; then
  echo "ERROR: credentials already exist for environment: $ENVIRONMENT"
  echo "Refusing to overwrite:"
  echo "  $KEY_FILE"
  exit 1
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_ROOT" "$KEY_DIR"

COMMENT="argocd-repo-${ENVIRONMENT}"

ssh-keygen \
  -q \
  -t ed25519 \
  -a 64 \
  -N "" \
  -C "$COMMENT" \
  -f "$KEY_FILE"

chmod 600 "$KEY_FILE"
chmod 644 "${KEY_FILE}.pub"

echo
echo "PASS: unique Argo CD repository deploy key generated"
echo
echo "Environment : $ENVIRONMENT"
echo "Repository  : ${REMOTE_URL:-unknown}"
echo "Private key : $KEY_FILE"
echo "Public key  : ${KEY_FILE}.pub"
echo
echo "Fingerprint:"
ssh-keygen -lf "${KEY_FILE}.pub"

echo
echo "SECURITY:"
echo "- The private key was generated outside the repository."
echo "- The private key was not printed."
echo "- Existing keys are never overwritten."
echo "- Use the public key as a READ-ONLY deploy key for the Git repository."
echo "- Use a different environment name to generate a different credential."
echo
echo "After registering the public key, set:"
printf 'export ARGO_REPO_SSH_KEY_FILE=%q\n' "$KEY_FILE"
