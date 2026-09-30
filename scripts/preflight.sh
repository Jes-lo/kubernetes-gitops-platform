#!/usr/bin/env bash

set -euo pipefail

EXPECTED_KIND_VERSION="0.33.0"
REQUIRED_KUBECTL_MAJOR="1"
REQUIRED_KUBECTL_MINOR="36"
MIN_TERRAFORM_VERSION="1.16.4"
MAX_TERRAFORM_VERSION="1.17.0"

FAILURES=0
WARNINGS=0

pass() {
  echo "PASS: $*"
}

warn() {
  echo "WARN: $*"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

version_ge() {
  local actual="$1"
  local minimum="$2"

  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

version_lt() {
  local actual="$1"
  local maximum="$2"

  [[ "$actual" != "$maximum" ]] &&
    [[ "$(printf '%s\n%s\n' "$actual" "$maximum" | sort -V | head -n1)" == "$actual" ]]
}

echo "===== KUBERNETES GITOPS PLATFORM PREFLIGHT ====="
echo

echo "===== REQUIRED COMMANDS ====="

REQUIRED_COMMANDS=(
  docker
  git
  jq
  kind
  kubectl
  ssh-keygen
  terraform
  timeout
)

for TOOL in "${REQUIRED_COMMANDS[@]}"; do
  if command -v "$TOOL" >/dev/null 2>&1; then
    pass "$TOOL found at $(command -v "$TOOL")"
  else
    fail "required command not found: $TOOL"
  fi
done

if command -v gh >/dev/null 2>&1; then
  pass "gh found at $(command -v gh)"
else
  warn "gh not found; deploy-key registration will require a manual GitHub step"
fi

if command -v make >/dev/null 2>&1; then
  pass "make found at $(command -v make)"
else
  warn "make not found; individual scripts can still be executed directly"
fi

echo
echo "===== GIT REPOSITORY ====="

if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  pass "Git repository detected: $REPO_ROOT"
else
  fail "run preflight from inside the Git repository"
  REPO_ROOT=""
fi

if [[ -n "$REPO_ROOT" ]]; then
  ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"

  if [[ -n "$ORIGIN_URL" ]]; then
    pass "origin remote configured: $ORIGIN_URL"
  else
    fail "origin remote is not configured"
  fi

  if git -C "$REPO_ROOT" diff --quiet &&
     git -C "$REPO_ROOT" diff --cached --quiet; then
    pass "tracked working tree is clean"
  else
    warn "tracked working tree contains uncommitted changes"
  fi
fi

echo
echo "===== VERSION CHECKS ====="

if command -v kind >/dev/null 2>&1; then
  KIND_VERSION="$(
    kind version 2>/dev/null |
      grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' |
      head -n1 |
      sed 's/^v//'
  )"

  if [[ "$KIND_VERSION" == "$EXPECTED_KIND_VERSION" ]]; then
    pass "kind version $KIND_VERSION"
  else
    fail "kind version is ${KIND_VERSION:-unknown}; expected $EXPECTED_KIND_VERSION"
  fi
fi

if command -v kubectl >/dev/null 2>&1 &&
   command -v jq >/dev/null 2>&1; then

  KUBECTL_VERSION="$(
    kubectl version --client -o json 2>/dev/null |
      jq -r '.clientVersion.gitVersion // empty' |
      sed 's/^v//'
  )"

  KUBECTL_MAJOR="${KUBECTL_VERSION%%.*}"
  KUBECTL_REMAINDER="${KUBECTL_VERSION#*.}"
  KUBECTL_MINOR="${KUBECTL_REMAINDER%%.*}"

  if [[ "$KUBECTL_MAJOR" == "$REQUIRED_KUBECTL_MAJOR" &&
        "$KUBECTL_MINOR" == "$REQUIRED_KUBECTL_MINOR" ]]; then
    pass "kubectl client version $KUBECTL_VERSION"
  else
    fail "kubectl client version is ${KUBECTL_VERSION:-unknown}; expected ${REQUIRED_KUBECTL_MAJOR}.${REQUIRED_KUBECTL_MINOR}.x"
  fi
fi

if command -v terraform >/dev/null 2>&1 &&
   command -v jq >/dev/null 2>&1; then

  TERRAFORM_VERSION="$(
    terraform version -json 2>/dev/null |
      jq -r '.terraform_version // empty'
  )"

  if [[ -n "$TERRAFORM_VERSION" ]] &&
     version_ge "$TERRAFORM_VERSION" "$MIN_TERRAFORM_VERSION" &&
     version_lt "$TERRAFORM_VERSION" "$MAX_TERRAFORM_VERSION"; then
    pass "Terraform version $TERRAFORM_VERSION"
  else
    fail "Terraform version is ${TERRAFORM_VERSION:-unknown}; required >=${MIN_TERRAFORM_VERSION} and <${MAX_TERRAFORM_VERSION}"
  fi
fi

echo
echo "===== DOCKER ENGINE ====="

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    DOCKER_SERVER_VERSION="$(
      docker version --format '{{.Server.Version}}' 2>/dev/null || true
    )"

    pass "Docker daemon reachable${DOCKER_SERVER_VERSION:+; server $DOCKER_SERVER_VERSION}"
  else
    fail "Docker CLI exists but Docker daemon is not reachable"
  fi
fi

echo
echo "===== REPRODUCIBILITY FILES ====="

if [[ -n "$REPO_ROOT" ]]; then
  if [[ -f "$REPO_ROOT/kind/cluster.yaml" ]]; then
    pass "kind/cluster.yaml exists"
  else
    fail "kind/cluster.yaml is missing"
  fi

  if [[ -f "$REPO_ROOT/terraform/bootstrap/.terraform.lock.hcl" ]]; then
    pass "Terraform dependency lock file exists"

    if git -C "$REPO_ROOT" ls-files --error-unmatch \
      terraform/bootstrap/.terraform.lock.hcl >/dev/null 2>&1; then
      pass "Terraform dependency lock file is tracked"
    else
      fail "Terraform dependency lock file is not tracked"
    fi
  else
    fail "Terraform dependency lock file is missing"
  fi

  PINNED_KIND_IMAGES="$(
    grep -Ec \
      'image:[[:space:]]+kindest/node:v1\.36\.4@sha256:[0-9a-f]{64}$' \
      "$REPO_ROOT/kind/cluster.yaml" \
      || true
  )"

  if [[ "$PINNED_KIND_IMAGES" -eq 3 ]]; then
    pass "all 3 kind nodes use the pinned Kubernetes image digest"
  else
    fail "expected 3 kind nodes pinned to Kubernetes v1.36.4 by digest; found $PINNED_KIND_IMAGES"
  fi
fi

echo
echo "===== SECRET / STATE SAFETY ====="

if [[ -n "$REPO_ROOT" ]]; then
  if git -C "$REPO_ROOT" ls-files |
     grep -Eq '\.tfstate($|\.)'; then
    fail "Terraform state appears to be tracked by Git"
  else
    pass "Terraform state is not tracked by Git"
  fi

  if git -C "$REPO_ROOT" ls-files |
     grep -Eq '\.kubeconfig$'; then
    fail "a kubeconfig appears to be tracked by Git"
  else
    pass "kubeconfig files are not tracked by Git"
  fi

  # Split the marker in source so this scanner does not match itself once tracked.
  PRIVATE_KEY_PATTERN="BEGIN OPENSSH PRIVATE"" KEY"

  PRIVATE_KEY_MATCHES="$(
    git -C "$REPO_ROOT" grep -Il \
      "$PRIVATE_KEY_PATTERN" \
      -- . \
      2>/dev/null \
      || true
  )"

  if [[ -z "$PRIVATE_KEY_MATCHES" ]]; then
    pass "no tracked OpenSSH private key material detected"
  else
    fail "tracked OpenSSH private key material detected"
    printf '%s\n' "$PRIVATE_KEY_MATCHES"
  fi
fi

echo
echo "===== OPTIONAL GITHUB AUTH ====="

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    pass "GitHub CLI authentication is available"
  else
    warn "GitHub CLI is installed but not authenticated"
  fi
fi

echo
echo "===== PREFLIGHT RESULT ====="

echo "failures=$FAILURES"
echo "warnings=$WARNINGS"

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: preflight checks failed"
  exit 1
fi

echo "PASS: environment is ready for reproducible bootstrap"
