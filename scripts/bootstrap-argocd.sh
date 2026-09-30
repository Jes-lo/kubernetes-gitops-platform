#!/usr/bin/env bash

set -euo pipefail

for TOOL in git jq kubectl terraform; do
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

TF_DIR="$REPO_ROOT/terraform/bootstrap"
KIND_CONFIG="$REPO_ROOT/kind/cluster.yaml"

if [[ ! -r "$KIND_CONFIG" ]]; then
  echo "ERROR: kind configuration not found"
  exit 1
fi

CLUSTER_NAME="$(
  awk '$1 == "name:" {print $2; exit}' "$KIND_CONFIG"
)"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: could not determine cluster name"
  exit 1
fi

EXPECTED_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
ARGO_NAMESPACE="argocd"
STATE_FILE="$TF_DIR/terraform.tfstate"

if [[ ! -f "$TF_DIR/.terraform.lock.hcl" ]]; then
  echo "ERROR: Terraform dependency lock file is missing"
  exit 1
fi

if ! kubectl config get-contexts -o name |
     grep -Fxq "$EXPECTED_CONTEXT"; then
  echo "ERROR: Kubernetes context not found:"
  echo "  $EXPECTED_CONTEXT"
  exit 1
fi

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  get --raw='/readyz' >/dev/null 2>&1; then
  echo "ERROR: Kubernetes API is not Ready on:"
  echo "  $EXPECTED_CONTEXT"
  exit 1
fi

echo "===== ARGO CD TERRAFORM BOOTSTRAP ====="
echo
echo "Terraform dir : $TF_DIR"
echo "Context       : $EXPECTED_CONTEXT"
echo "Namespace     : $ARGO_NAMESPACE"
echo "State         : $STATE_FILE"

echo
echo "===== TERRAFORM INIT ====="

terraform \
  -chdir="$TF_DIR" \
  init \
  -input=false \
  -lockfile=readonly

echo
echo "===== TERRAFORM VALIDATE ====="

terraform \
  -chdir="$TF_DIR" \
  validate

#
# Safety boundary:
# An existing Argo CD installation must not be silently adopted by a
# new local Terraform state.
#
ARGO_NAMESPACE_EXISTS=false

if kubectl \
  --context "$EXPECTED_CONTEXT" \
  get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
  ARGO_NAMESPACE_EXISTS=true
fi

if [[ "$ARGO_NAMESPACE_EXISTS" == "true" &&
      ! -f "$STATE_FILE" ]]; then
  echo
  echo "ERROR: Argo CD namespace already exists but Terraform state is absent."
  echo "Refusing to adopt or overwrite an unmanaged/existing installation."
  exit 1
fi

if [[ -f "$STATE_FILE" ]]; then
  echo
  echo "===== TERRAFORM STATE SAFETY ====="

  mapfile -t STATE_RESOURCES < <(
    terraform \
      -chdir="$TF_DIR" \
      state list
  )

  printf '%s\n' "${STATE_RESOURCES[@]}"

  for RESOURCE in \
    kubernetes_namespace_v1.argocd \
    helm_release.argocd
  do
    if printf '%s\n' "${STATE_RESOURCES[@]}" |
       grep -Fxq "$RESOURCE"; then
      echo "PASS: state tracks $RESOURCE"
    else
      if [[ "$ARGO_NAMESPACE_EXISTS" == "true" ]]; then
        echo "ERROR: existing Argo CD installation is not fully represented in Terraform state"
        echo "Missing state resource: $RESOURCE"
        exit 1
      fi
    fi
  done
fi

PLAN_FILE="$(
  mktemp /tmp/kubernetes-gitops-argocd.XXXXXX.tfplan
)"

cleanup() {
  rm -f "$PLAN_FILE"
}

trap cleanup EXIT

echo
echo "===== TERRAFORM PLAN ====="

set +e

terraform \
  -chdir="$TF_DIR" \
  plan \
  -input=false \
  -lock=true \
  -detailed-exitcode \
  -var="kube_context=$EXPECTED_CONTEXT" \
  -out="$PLAN_FILE"

PLAN_RC=$?

set -e

case "$PLAN_RC" in
  0)
    echo
    echo "PASS: Terraform reports no infrastructure changes"
    ;;

  2)
    echo
    echo "INFO: Terraform has bootstrap changes to apply"

    echo
    echo "===== PLANNED ACTIONS ====="

    terraform \
      -chdir="$TF_DIR" \
      show \
      -json \
      "$PLAN_FILE" \
    | jq -r '
        .resource_changes[]?
        | "\(.address): \(.change.actions | join(","))"
      '

    echo
    echo "===== TERRAFORM APPLY ====="

    terraform \
      -chdir="$TF_DIR" \
      apply \
      -input=false \
      -auto-approve \
      "$PLAN_FILE"

    echo
    echo "PASS: Terraform bootstrap applied"
    ;;

  *)
    echo
    echo "ERROR: terraform plan failed with exit code $PLAN_RC"
    exit "$PLAN_RC"
    ;;
esac

echo
echo "===== VERIFY ARGO CD ====="

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Argo CD namespace does not exist after bootstrap"
  exit 1
fi

echo "PASS: Argo CD namespace exists"

kubectl \
  --context "$EXPECTED_CONTEXT" \
  wait \
  --for=condition=Ready \
  pod \
  --all \
  -n "$ARGO_NAMESPACE" \
  --timeout=300s

echo
echo "===== ARGO CD PODS ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  get pods \
  -n "$ARGO_NAMESPACE" \
  -o wide

echo
echo "===== TERRAFORM OUTPUTS ====="

terraform \
  -chdir="$TF_DIR" \
  output

echo
echo "PASS: Argo CD bootstrap is healthy"
echo
echo "SAFETY:"
echo "- Terraform uses the explicit Kubernetes context."
echo "- Provider dependencies use the committed lockfile."
echo "- Existing Argo CD without matching Terraform state is never adopted."
echo "- Terraform plans are stored temporarily outside the repository."
echo "- No credentials are managed by this Terraform bootstrap."
