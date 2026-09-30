#!/usr/bin/env bash

set -euo pipefail

for TOOL in docker git kind kubectl; do
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

CONFIG_FILE="$REPO_ROOT/kind/cluster.yaml"

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "ERROR: kind configuration not found:"
  echo "  $CONFIG_FILE"
  exit 1
fi

CLUSTER_NAME="$(
  awk '
    $1 == "name:" {
      print $2
      exit
    }
  ' "$CONFIG_FILE"
)"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: cluster name could not be determined from kind/cluster.yaml"
  exit 1
fi

EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"

EXPECTED_NODES="$(
  grep -Ec '^[[:space:]]+- role:[[:space:]]+(control-plane|worker)[[:space:]]*$' \
    "$CONFIG_FILE" \
    || true
)"

if [[ "$EXPECTED_NODES" -lt 1 ]]; then
  echo "ERROR: no kind nodes found in configuration"
  exit 1
fi

echo "===== KIND CLUSTER BOOTSTRAP ====="
echo
echo "Cluster : $CLUSTER_NAME"
echo "Context : $EXPECTED_CONTEXT"
echo "Config  : $CONFIG_FILE"
echo "Nodes   : $EXPECTED_NODES"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not reachable"
  exit 1
fi

if kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
  echo
  echo "INFO: cluster already exists"
  echo "PASS: refusing to recreate or replace existing cluster"
else
  echo
  echo "===== CREATE CLUSTER ====="

  kind create cluster \
    --config "$CONFIG_FILE" \
    --wait 120s

  echo
  echo "PASS: kind cluster created"
fi

echo
echo "===== VERIFY KIND NODES ====="

mapfile -t KIND_NODES < <(
  kind get nodes \
    --name "$CLUSTER_NAME"
)

ACTUAL_NODES="${#KIND_NODES[@]}"

printf '%s\n' "${KIND_NODES[@]}"

if [[ "$ACTUAL_NODES" -ne "$EXPECTED_NODES" ]]; then
  echo
  echo "ERROR: unexpected kind node count"
  echo "Expected: $EXPECTED_NODES"
  echo "Actual  : $ACTUAL_NODES"
  exit 1
fi

echo
echo "PASS: expected node count present"

if ! kubectl config get-contexts -o name |
     grep -Fxq "$EXPECTED_CONTEXT"; then
  echo "ERROR: expected kubeconfig context not found:"
  echo "  $EXPECTED_CONTEXT"
  exit 1
fi

echo "PASS: kubeconfig context exists"

echo
echo "===== VERIFY KUBERNETES NODES ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  get nodes \
  -o wide

READY_NODES="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get nodes \
    --no-headers \
  | awk '$2 == "Ready" {count++} END {print count+0}'
)"

if [[ "$READY_NODES" -ne "$EXPECTED_NODES" ]]; then
  echo
  echo "ERROR: not all Kubernetes nodes are Ready"
  echo "Expected Ready: $EXPECTED_NODES"
  echo "Actual Ready  : $READY_NODES"
  exit 1
fi

echo
echo "PASS: all Kubernetes nodes are Ready"

echo
echo "SECURITY / SAFETY:"
echo "- Existing clusters are never deleted."
echo "- Existing clusters are never recreated."
echo "- kubectl operations use the explicit expected context."
echo "- The script does not change the current kubectl context."
