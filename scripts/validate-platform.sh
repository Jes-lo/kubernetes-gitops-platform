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

CLUSTER_NAME="$(
  awk '$1 == "name:" {print $2; exit}' "$KIND_CONFIG"
)"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: could not determine cluster name"
  exit 1
fi

EXPECTED_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
KAFKA_NAMESPACE="platform-kafka"

FAILURES=0

pass() {
  echo "PASS: $*"
}

fail() {
  echo "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

echo "===== PLATFORM VALIDATION ====="
echo
echo "Context : $EXPECTED_CONTEXT"

echo
echo "===== KUBERNETES ====="

if kubectl config get-contexts -o name |
   grep -Fxq "$EXPECTED_CONTEXT"; then
  pass "expected Kubernetes context exists"
else
  fail "expected Kubernetes context does not exist"
fi

if kubectl \
  --context "$EXPECTED_CONTEXT" \
  get --raw='/readyz' >/dev/null 2>&1; then
  pass "Kubernetes API is Ready"
else
  fail "Kubernetes API is not Ready"
fi

EXPECTED_NODES="$(
  grep -Ec \
    '^[[:space:]]+- role:[[:space:]]+(control-plane|worker)[[:space:]]*$' \
    "$KIND_CONFIG" \
    || true
)"

READY_NODES="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get nodes \
    --no-headers 2>/dev/null \
  | awk '$2 == "Ready" {count++} END {print count+0}'
)"

if [[ "$READY_NODES" -eq "$EXPECTED_NODES" ]]; then
  pass "all $EXPECTED_NODES Kubernetes nodes are Ready"
else
  fail "Ready node count is $READY_NODES; expected $EXPECTED_NODES"
fi

echo
echo "===== ARGO CD ====="

REQUIRED_APPLICATIONS=(
  demo-api
  demo-dev-bootstrap
  kafka-platform
  strimzi-operator
)

for APP in "${REQUIRED_APPLICATIONS[@]}"; do
  APP_JSON="$(
    kubectl \
      --context "$EXPECTED_CONTEXT" \
      get application "$APP" \
      -n "$ARGO_NAMESPACE" \
      -o json \
      2>/dev/null \
      || true
  )"

  if [[ -z "$APP_JSON" ]]; then
    fail "Argo CD Application missing: $APP"
    continue
  fi

  SYNC="$(
    jq -r '.status.sync.status // ""' <<<"$APP_JSON"
  )"

  HEALTH="$(
    jq -r '.status.health.status // ""' <<<"$APP_JSON"
  )"

  if [[ "$SYNC" == "Synced" &&
        "$HEALTH" == "Healthy" ]]; then
    pass "$APP is Synced/Healthy"
  else
    fail "$APP state is sync=${SYNC:-unknown} health=${HEALTH:-unknown}"
  fi
done

mapfile -t REPO_URLS < <(
  grep -RhoE \
    'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git' \
    "$REPO_ROOT/gitops" \
  | sort -u
)

if [[ "${#REPO_URLS[@]}" -eq 1 ]]; then
  REPO_URL="${REPO_URLS[0]}"

  REPO_SECRET_COUNT="$(
    kubectl \
      --context "$EXPECTED_CONTEXT" \
      get secrets \
      -n "$ARGO_NAMESPACE" \
      -l argocd.argoproj.io/secret-type=repository \
      -o json \
    | jq \
        --arg repo "$REPO_URL" '
          [
            .items[]
            | select(
                ((.data.url // "") | @base64d) == $repo
              )
          ]
          | length
        '
  )"

  if [[ "$REPO_SECRET_COUNT" -eq 1 ]]; then
    pass "exactly one Argo CD repository credential exists"
  else
    fail "expected exactly one repository credential; found $REPO_SECRET_COUNT"
  fi
else
  fail "expected exactly one GitOps SSH repository URL"
fi

echo
echo "===== STRIMZI ====="

AVAILABLE_OPERATOR_REPLICAS="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get deployment strimzi-cluster-operator \
    -n "$KAFKA_NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' \
    2>/dev/null \
    || true
)"

if [[ "$AVAILABLE_OPERATOR_REPLICAS" == "1" ]]; then
  pass "Strimzi operator has 1 available replica"
else
  fail "Strimzi operator available replicas=${AVAILABLE_OPERATOR_REPLICAS:-0}"
fi

STRIMZI_CRDS=(
  kafkas.kafka.strimzi.io
  kafkanodepools.kafka.strimzi.io
  kafkatopics.kafka.strimzi.io
  kafkausers.kafka.strimzi.io
)

for CRD in "${STRIMZI_CRDS[@]}"; do
  ESTABLISHED="$(
    kubectl \
      --context "$EXPECTED_CONTEXT" \
      get crd "$CRD" \
      -o json \
      2>/dev/null \
    | jq -r '
        [
          .status.conditions[]?
          | select(
              .type == "Established"
              and .status == "True"
            )
        ]
        | length
      ' \
      2>/dev/null \
      || echo 0
  )"

  if [[ "$ESTABLISHED" -eq 1 ]]; then
    pass "$CRD is Established"
  else
    fail "$CRD is not Established"
  fi
done

echo
echo "===== KAFKA CLUSTER ====="

KAFKA_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get kafka platform-kafka \
    -n "$KAFKA_NAMESPACE" \
    -o json \
    2>/dev/null \
    || true
)"

if [[ -z "$KAFKA_JSON" ]]; then
  fail "Kafka resource platform-kafka is missing"
else
  KAFKA_READY="$(
    jq -r '
      [
        .status.conditions[]?
        | select(
            .type == "Ready"
            and .status == "True"
          )
      ]
      | length
    ' <<<"$KAFKA_JSON"
  )"

  KAFKA_VERSION="$(
    jq -r '.status.kafkaVersion // ""' <<<"$KAFKA_JSON"
  )"

  METADATA_VERSION="$(
    jq -r '.status.kafkaMetadataVersion // ""' <<<"$KAFKA_JSON"
  )"

  if [[ "$KAFKA_READY" -eq 1 ]]; then
    pass "Kafka platform-kafka is Ready"
  else
    fail "Kafka platform-kafka is not Ready"
  fi

  if [[ "$KAFKA_VERSION" == "4.3.1" ]]; then
    pass "Kafka runtime version is 4.3.1"
  else
    fail "Kafka runtime version is ${KAFKA_VERSION:-unknown}"
  fi

  if [[ "$METADATA_VERSION" == "4.3-IV0" ]]; then
    pass "Kafka metadata version is 4.3-IV0"
  else
    fail "Kafka metadata version is ${METADATA_VERSION:-unknown}"
  fi
fi

echo
echo "===== KAFKA NODE POOL ====="

NODE_POOL_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get kafkanodepool dual-role \
    -n "$KAFKA_NAMESPACE" \
    -o json \
    2>/dev/null \
    || true
)"

if [[ -z "$NODE_POOL_JSON" ]]; then
  fail "KafkaNodePool dual-role is missing"
else
  REPLICAS="$(
    jq -r '.spec.replicas // 0' <<<"$NODE_POOL_JSON"
  )"

  NODE_ID_COUNT="$(
    jq '.status.nodeIds // [] | length' <<<"$NODE_POOL_JSON"
  )"

  HAS_BROKER="$(
    jq '
      (.spec.roles // [])
      | index("broker") != null
    ' <<<"$NODE_POOL_JSON"
  )"

  HAS_CONTROLLER="$(
    jq '
      (.spec.roles // [])
      | index("controller") != null
    ' <<<"$NODE_POOL_JSON"
  )"

  if [[ "$REPLICAS" -eq 3 &&
        "$NODE_ID_COUNT" -eq 3 ]]; then
    pass "KafkaNodePool has 3 desired and 3 assigned nodes"
  else
    fail "KafkaNodePool replicas=$REPLICAS nodeIds=$NODE_ID_COUNT"
  fi

  if [[ "$HAS_BROKER" == "true" &&
        "$HAS_CONTROLLER" == "true" ]]; then
    pass "KafkaNodePool uses controller+broker dual roles"
  else
    fail "KafkaNodePool roles are incomplete"
  fi
fi

echo
echo "===== KAFKA PODS ====="

BROKER_PODS_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get pods \
    -n "$KAFKA_NAMESPACE" \
    -l 'strimzi.io/cluster=platform-kafka,strimzi.io/broker-role=true' \
    -o json
)"

BROKER_POD_COUNT="$(
  jq '.items | length' <<<"$BROKER_PODS_JSON"
)"

READY_BROKER_PODS="$(
  jq '
    [
      .items[]
      | select(
          .status.phase == "Running"
          and (
            [
              .status.containerStatuses[]?
              | select(.ready == true)
            ]
            | length
          ) == (.status.containerStatuses | length)
        )
    ]
    | length
  ' <<<"$BROKER_PODS_JSON"
)"

if [[ "$BROKER_POD_COUNT" -eq 3 &&
      "$READY_BROKER_PODS" -eq 3 ]]; then
  pass "all 3 Kafka pods are Running/Ready"
else
  fail "Kafka pods total=$BROKER_POD_COUNT ready=$READY_BROKER_PODS"
fi

echo
echo "===== PERSISTENT STORAGE ====="

PVC_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get pvc \
    -n "$KAFKA_NAMESPACE" \
    -o json
)"

KAFKA_PVC_COUNT="$(
  jq '
    [
      .items[]
      | select(
          .metadata.name
          | test("^data-0-platform-kafka-dual-role-[0-9]+$")
        )
    ]
    | length
  ' <<<"$PVC_JSON"
)"

BOUND_KAFKA_PVCS="$(
  jq '
    [
      .items[]
      | select(
          (.metadata.name
            | test("^data-0-platform-kafka-dual-role-[0-9]+$"))
          and .status.phase == "Bound"
          and .spec.storageClassName == "standard"
          and .status.capacity.storage == "1Gi"
        )
    ]
    | length
  ' <<<"$PVC_JSON"
)"

if [[ "$KAFKA_PVC_COUNT" -eq 3 &&
      "$BOUND_KAFKA_PVCS" -eq 3 ]]; then
  pass "3 Kafka PVCs are Bound, standard, 1Gi"
else
  fail "Kafka PVCs total=$KAFKA_PVC_COUNT compliant=$BOUND_KAFKA_PVCS"
fi

echo
echo "===== TOPIC ====="

TOPIC_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get kafkatopic platform-events \
    -n "$KAFKA_NAMESPACE" \
    -o json \
    2>/dev/null \
    || true
)"

if [[ -z "$TOPIC_JSON" ]]; then
  fail "KafkaTopic platform-events is missing"
else
  TOPIC_READY="$(
    jq '
      [
        .status.conditions[]?
        | select(
            .type == "Ready"
            and .status == "True"
          )
      ]
      | length
    ' <<<"$TOPIC_JSON"
  )"

  PARTITIONS="$(
    jq -r '.spec.partitions // 0' <<<"$TOPIC_JSON"
  )"

  REPLICAS="$(
    jq -r '.spec.replicas // 0' <<<"$TOPIC_JSON"
  )"

  if [[ "$TOPIC_READY" -eq 1 &&
        "$PARTITIONS" -eq 3 &&
        "$REPLICAS" -eq 3 ]]; then
    pass "platform-events is Ready with 3 partitions / RF 3"
  else
    fail "platform-events validation failed"
  fi
fi

echo
echo "===== KAFKA USER ====="

USER_JSON="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get kafkauser demo-client \
    -n "$KAFKA_NAMESPACE" \
    -o json \
    2>/dev/null \
    || true
)"

if [[ -z "$USER_JSON" ]]; then
  fail "KafkaUser demo-client is missing"
else
  USER_READY="$(
    jq '
      [
        .status.conditions[]?
        | select(
            .type == "Ready"
            and .status == "True"
          )
      ]
      | length
    ' <<<"$USER_JSON"
  )"

  AUTH_TYPE="$(
    jq -r '.spec.authentication.type // ""' <<<"$USER_JSON"
  )"

  AUTHZ_TYPE="$(
    jq -r '.spec.authorization.type // ""' <<<"$USER_JSON"
  )"

  if [[ "$USER_READY" -eq 1 &&
        "$AUTH_TYPE" == "tls" &&
        "$AUTHZ_TYPE" == "simple" ]]; then
    pass "demo-client is Ready with TLS + simple authorization"
  else
    fail "demo-client validation failed"
  fi
fi

echo
echo "===== RUNTIME SECRET STRUCTURE ====="

DEMO_SECRET_KEYS="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get secret demo-client \
    -n "$KAFKA_NAMESPACE" \
    -o json \
  | jq -r '.data | keys[]'
)"

for KEY in \
  ca.crt \
  user.crt \
  user.key \
  user.p12 \
  user.password
do
  if grep -Fxq "$KEY" <<<"$DEMO_SECRET_KEYS"; then
    pass "demo-client contains required key: $KEY"
  else
    fail "demo-client missing required key: $KEY"
  fi
done

CA_SECRET_KEYS="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get secret platform-kafka-cluster-ca-cert \
    -n "$KAFKA_NAMESPACE" \
    -o json \
  | jq -r '.data | keys[]'
)"

for KEY in \
  ca.crt \
  ca.p12 \
  ca.password
do
  if grep -Fxq "$KEY" <<<"$CA_SECRET_KEYS"; then
    pass "cluster CA contains required key: $KEY"
  else
    fail "cluster CA missing required key: $KEY"
  fi
done

echo
echo "===== SOURCE CONTROL SECRET SAFETY ====="

TRACKED_SECRET_MANIFESTS="$(
  git -C "$REPO_ROOT" grep -Il \
    -E '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' \
    -- \
    '*.yaml' \
    '*.yml' \
    2>/dev/null \
    || true
)"

if [[ -z "$TRACKED_SECRET_MANIFESTS" ]]; then
  pass "no Kubernetes Secret manifests are tracked"
else
  fail "tracked Kubernetes Secret manifest(s) detected"
  printf '%s\n' "$TRACKED_SECRET_MANIFESTS"
fi

if git -C "$REPO_ROOT" ls-files |
   grep -Eq '\.tfstate($|\.)'; then
  fail "Terraform state is tracked by Git"
else
  pass "Terraform state is not tracked by Git"
fi

echo
echo "===== VALIDATION RESULT ====="
echo "failures=$FAILURES"

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL: platform validation failed"
  exit 1
fi

echo "PASS: platform validation completed successfully"
