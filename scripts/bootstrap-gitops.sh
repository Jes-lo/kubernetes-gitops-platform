#!/usr/bin/env bash

set -euo pipefail

for TOOL in git jq kubectl; do
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

KIND_CONFIG="$REPO_ROOT/kind/cluster.yaml"
PROJECT_DIR="$REPO_ROOT/gitops/projects"
APPLICATION_DIR="$REPO_ROOT/gitops/applications"

CLUSTER_NAME="$(
  awk '$1 == "name:" {print $2; exit}' "$KIND_CONFIG"
)"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: could not determine cluster name"
  exit 1
fi

EXPECTED_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"

for DIR in "$PROJECT_DIR" "$APPLICATION_DIR"; do
  if [[ ! -d "$DIR" ]]; then
    echo "ERROR: required directory missing:"
    echo "  $DIR"
    exit 1
  fi
done

if ! kubectl config get-contexts -o name |
     grep -Fxq "$EXPECTED_CONTEXT"; then
  echo "ERROR: expected Kubernetes context does not exist:"
  echo "  $EXPECTED_CONTEXT"
  exit 1
fi

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  get --raw='/readyz' >/dev/null 2>&1; then
  echo "ERROR: Kubernetes API is not Ready"
  exit 1
fi

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Argo CD is not installed"
  echo "Run:"
  echo "  ./scripts/bootstrap-argocd.sh"
  exit 1
fi

mapfile -t REPO_URLS < <(
  grep -RhoE \
    'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git' \
    "$REPO_ROOT/gitops" \
  | sort -u
)

if [[ "${#REPO_URLS[@]}" -ne 1 ]]; then
  echo "ERROR: expected exactly one GitOps SSH repository"
  echo "Found: ${#REPO_URLS[@]}"
  exit 1
fi

REPO_URL="${REPO_URLS[0]}"

echo "===== GITOPS BOOTSTRAP ====="
echo
echo "Context    : $EXPECTED_CONTEXT"
echo "Argo CD NS : $ARGO_NAMESPACE"
echo "Repository : $REPO_URL"

echo
echo "===== VERIFY REPOSITORY AUTH ====="

mapfile -t REPO_SECRETS < <(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get secrets \
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
)

if [[ "${#REPO_SECRETS[@]}" -ne 1 ]]; then
  echo "ERROR: expected exactly one Argo CD credential for repository"
  echo "Found: ${#REPO_SECRETS[@]}"

  if [[ "${#REPO_SECRETS[@]}" -gt 0 ]]; then
    printf '  %s\n' "${REPO_SECRETS[@]}"
  fi

  exit 1
fi

echo "PASS: exactly one Argo CD repository credential exists"
echo "Secret: ${REPO_SECRETS[0]}"

echo
echo "===== APPLY APPPROJECTS ====="

mapfile -t PROJECT_FILES < <(
  find "$PROJECT_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.yaml' \
  | sort
)

if [[ "${#PROJECT_FILES[@]}" -eq 0 ]]; then
  echo "ERROR: no AppProject manifests found"
  exit 1
fi

for FILE in "${PROJECT_FILES[@]}"; do
  echo "Applying: ${FILE#$REPO_ROOT/}"

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    apply \
    -f "$FILE"
done

echo
echo "PASS: AppProjects applied"

echo
echo "===== APPLY BASE APPLICATIONS ====="

mapfile -t APPLICATION_FILES < <(
  find "$APPLICATION_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.yaml' \
  | sort
)

if [[ "${#APPLICATION_FILES[@]}" -eq 0 ]]; then
  echo "ERROR: no Argo CD Application manifests found"
  exit 1
fi

KAFKA_APPLICATION_FILE="$APPLICATION_DIR/kafka-platform.yaml"

if [[ ! -f "$KAFKA_APPLICATION_FILE" ]]; then
  echo "ERROR: Kafka Application manifest missing:"
  echo "  $KAFKA_APPLICATION_FILE"
  exit 1
fi

for FILE in "${APPLICATION_FILES[@]}"; do
  if [[ "$FILE" == "$KAFKA_APPLICATION_FILE" ]]; then
    continue
  fi

  echo "Applying: ${FILE#$REPO_ROOT/}"

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    apply \
    -f "$FILE"
done

echo
echo "PASS: base Applications applied"

wait_for_application() {
  local application="$1"
  local max_attempts="${2:-150}"

  echo
  echo "===== WAIT FOR APPLICATION: $application ====="

  for attempt in $(seq 1 "$max_attempts"); do
    local sync
    local health

    sync="$(
      kubectl \
        --context "$EXPECTED_CONTEXT" \
        get application "$application" \
        -n "$ARGO_NAMESPACE" \
        -o jsonpath='{.status.sync.status}' \
        2>/dev/null \
        || true
    )"

    health="$(
      kubectl \
        --context "$EXPECTED_CONTEXT" \
        get application "$application" \
        -n "$ARGO_NAMESPACE" \
        -o jsonpath='{.status.health.status}' \
        2>/dev/null \
        || true
    )"

    echo "attempt=$attempt sync=${sync:-unknown} health=${health:-unknown}"

    if [[ "$sync" == "Synced" &&
          "$health" == "Healthy" ]]; then
      echo "PASS: $application is Synced/Healthy"
      return 0
    fi

    sleep 2
  done

  echo "ERROR: $application did not become Synced/Healthy"
  return 1
}

#
# Kafka CRs must not be enabled until the Strimzi operator and its CRDs exist.
#
wait_for_application "strimzi-operator"

echo
echo "===== VERIFY STRIMZI CRDs ====="

STRIMZI_CRDS=(
  kafkas.kafka.strimzi.io
  kafkanodepools.kafka.strimzi.io
  kafkatopics.kafka.strimzi.io
  kafkausers.kafka.strimzi.io
)

for CRD in "${STRIMZI_CRDS[@]}"; do
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    wait \
    --for=condition=Established \
    "crd/$CRD" \
    --timeout=120s

  echo "PASS: $CRD established"
done

echo
echo "===== VERIFY STRIMZI OPERATOR ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  rollout status \
  deployment/strimzi-cluster-operator \
  -n platform-kafka \
  --timeout=180s

echo "PASS: Strimzi operator available"

echo
echo "===== APPLY KAFKA APPLICATION ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  apply \
  -f "$KAFKA_APPLICATION_FILE"

echo
echo "PASS: Kafka Application applied"

wait_for_application "kafka-platform" 300

echo
echo "===== WAIT FOR KAFKA READY ====="

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  wait \
  kafka/platform-kafka \
  -n platform-kafka \
  --for=condition=Ready \
  --timeout=600s; then

  echo
  echo "ERROR: Kafka did not become Ready"
  echo
  echo "===== KAFKA PODS ====="

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get pods \
    -n platform-kafka \
    -o wide \
    || true

  echo
  echo "===== RECENT EVENTS ====="

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get events \
    -n platform-kafka \
    --sort-by='.lastTimestamp' \
  | tail -n 40 \
    || true

  exit 1
fi

echo "PASS: Kafka cluster is Ready"

echo
echo "===== FINAL ARGO CD APPLICATIONS ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  get applications \
  -n "$ARGO_NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

echo
echo "===== FINAL KAFKA PLATFORM ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  get \
  kafka,kafkanodepool,kafkatopic,kafkauser \
  -n platform-kafka \
  -o wide

echo
echo "PASS: GitOps platform bootstrap completed"

echo
echo "SAFETY:"
echo "- Repository credentials must exist before GitOps bootstrap."
echo "- AppProjects are established before Applications."
echo "- Kafka is not enabled until Strimzi and required CRDs are ready."
echo "- All kubectl operations use the explicit expected context."
echo "- No Secret values are read or printed."
echo "- No workload manifests are applied directly; Argo CD remains the reconciler."
