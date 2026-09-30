#!/usr/bin/env bash

set -euo pipefail

for TOOL in git kubectl; do
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
KAFKA_NAMESPACE="platform-kafka"
KAFKA_CLUSTER="platform-kafka"
KAFKA_TOPIC="platform-events"
KAFKA_USER="demo-client"
BOOTSTRAP_SERVER="platform-kafka-kafka-bootstrap.platform-kafka.svc:9093"
CLIENT_IMAGE="quay.io/strimzi/kafka:1.2.0-kafka-4.3.1"

POD_NAME="kafka-mtls-validation-$(date +%s)-$$"

cleanup() {
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    delete pod "$POD_NAME" \
    -n "$KAFKA_NAMESPACE" \
    --ignore-not-found \
    --wait=false \
    >/dev/null 2>&1 \
    || true

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    wait \
    --for=delete \
    "pod/$POD_NAME" \
    -n "$KAFKA_NAMESPACE" \
    --timeout=120s \
    >/dev/null 2>&1 \
    || true
}

trap cleanup EXIT INT TERM

echo "===== KAFKA mTLS / ACL VALIDATION ====="
echo
echo "Context   : $EXPECTED_CONTEXT"
echo "Namespace : $KAFKA_NAMESPACE"
echo "Cluster   : $KAFKA_CLUSTER"
echo "Topic     : $KAFKA_TOPIC"
echo "User      : $KAFKA_USER"

echo
echo "===== PLATFORM HEALTH GATE ====="

"$REPO_ROOT/scripts/validate-platform.sh"

echo
echo "===== CREATE EPHEMERAL CLIENT ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  apply -f - <<EOF_POD
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${KAFKA_NAMESPACE}
  labels:
    app: kafka-mtls-validation
spec:
  restartPolicy: Never

  containers:
    - name: kafka-client
      image: ${CLIENT_IMAGE}
      imagePullPolicy: IfNotPresent

      command:
        - sh
        - -c
        - sleep 3600

      env:
        - name: USER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${KAFKA_USER}
              key: user.password

        - name: CA_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${KAFKA_CLUSTER}-cluster-ca-cert
              key: ca.password

      volumeMounts:
        - name: user-credentials
          mountPath: /opt/kafka/client/user
          readOnly: true

        - name: cluster-ca
          mountPath: /opt/kafka/client/ca
          readOnly: true

  volumes:
    - name: user-credentials
      secret:
        secretName: ${KAFKA_USER}

    - name: cluster-ca
      secret:
        secretName: ${KAFKA_CLUSTER}-cluster-ca-cert
EOF_POD

if ! kubectl \
  --context "$EXPECTED_CONTEXT" \
  wait \
  --for=condition=Ready \
  "pod/$POD_NAME" \
  -n "$KAFKA_NAMESPACE" \
  --timeout=180s; then

  echo
  echo "ERROR: Kafka client Pod did not become Ready"

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    get pod "$POD_NAME" \
    -n "$KAFKA_NAMESPACE" \
    -o wide \
    || true

  echo
  echo "===== CLIENT POD EVENTS ====="

  kubectl \
    --context "$EXPECTED_CONTEXT" \
    describe pod "$POD_NAME" \
    -n "$KAFKA_NAMESPACE" \
  | sed -n '/Events:/,$p' \
    || true

  exit 1
fi

echo "PASS: ephemeral Kafka client is Ready"

echo
echo "===== VERIFY CREDENTIAL MOUNTS ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  exec \
  -n "$KAFKA_NAMESPACE" \
  "$POD_NAME" \
  -- sh -c '
    set -eu

    for FILE in \
      /opt/kafka/client/user/user.p12 \
      /opt/kafka/client/user/user.crt \
      /opt/kafka/client/user/user.key \
      /opt/kafka/client/ca/ca.p12 \
      /opt/kafka/client/ca/ca.crt
    do
      test -r "$FILE"
    done
  '

echo "PASS: required credential files are mounted"

echo
echo "===== CREATE IN-POD mTLS CONFIG ====="

kubectl \
  --context "$EXPECTED_CONTEXT" \
  exec \
  -n "$KAFKA_NAMESPACE" \
  "$POD_NAME" \
  -- sh -c '
    set -eu
    umask 077

    cat > /tmp/client.properties <<EOF_CONFIG
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/opt/kafka/client/ca/ca.p12
ssl.truststore.password=${CA_PASSWORD}
ssl.keystore.type=PKCS12
ssl.keystore.location=/opt/kafka/client/user/user.p12
ssl.keystore.password=${USER_PASSWORD}
EOF_CONFIG

    test -s /tmp/client.properties
    test "$(stat -c "%a" /tmp/client.properties)" = "600"
  '

echo "PASS: protected mTLS client configuration created inside Pod"

echo
echo "===== POSITIVE AUTHORIZATION TEST ====="

TEST_MESSAGE="kafka-mtls-validation-$(date +%s)-$$"

echo "Message: $TEST_MESSAGE"

printf '%s\n' "$TEST_MESSAGE" \
| kubectl \
    --context "$EXPECTED_CONTEXT" \
    exec \
    -i \
    -n "$KAFKA_NAMESPACE" \
    "$POD_NAME" \
    -- /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --topic "$KAFKA_TOPIC" \
      --command-config /tmp/client.properties

echo "PASS: producer write succeeded"

set +e

CONSUMER_OUTPUT="$(
  kubectl \
    --context "$EXPECTED_CONTEXT" \
    exec \
    -n "$KAFKA_NAMESPACE" \
    "$POD_NAME" \
    -- /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --topic "$KAFKA_TOPIC" \
      --group "$KAFKA_USER" \
      --from-beginning \
      --timeout-ms 30000 \
      --consumer.config /tmp/client.properties \
    2>/dev/null
)"

CONSUMER_RC=$?

set -e

if grep -Fxq "$TEST_MESSAGE" <<<"$CONSUMER_OUTPUT"; then
  echo "PASS: consumer read the exact produced message"
else
  echo "ERROR: produced message was not observed by authorized consumer"
  echo "Consumer exit code: $CONSUMER_RC"
  exit 1
fi

echo
echo "PASS: mTLS authentication + authorized produce/consume succeeded"

echo
echo "===== NEGATIVE AUTHORIZATION TEST ====="

set +e

DENIED_OUTPUT="$(
  timeout 30s \
    kubectl \
      --context "$EXPECTED_CONTEXT" \
      exec \
      -n "$KAFKA_NAMESPACE" \
      "$POD_NAME" \
      -- /opt/kafka/bin/kafka-configs.sh \
        --bootstrap-server "$BOOTSTRAP_SERVER" \
        --entity-type topics \
        --entity-name "$KAFKA_TOPIC" \
        --describe \
        --command-config /tmp/client.properties \
      2>&1
)"

DENIED_RC=$?

set -e

if [[ "$DENIED_RC" -ne 0 ]] &&
   grep -Eq \
     'TopicAuthorizationException|ClusterAuthorizationException|authorization failed' \
     <<<"$DENIED_OUTPUT"; then

  echo "PASS: unauthorized DescribeConfigs operation was blocked"
else
  echo "ERROR: expected Kafka authorization denial was not observed"
  echo "exit_code=$DENIED_RC"
  echo "$DENIED_OUTPUT"
  exit 1
fi

echo
echo "===== CLEANUP ====="

cleanup

if kubectl \
  --context "$EXPECTED_CONTEXT" \
  get pod "$POD_NAME" \
  -n "$KAFKA_NAMESPACE" \
  >/dev/null 2>&1; then

  echo "ERROR: ephemeral validation Pod still exists after cleanup timeout"
  exit 1
fi

echo "PASS: ephemeral validation Pod removed"

trap - EXIT INT TERM

echo
echo "===== FUNCTIONAL VALIDATION RESULT ====="
echo "PASS: Kafka mTLS functional validation completed successfully"

echo
echo "Validated:"
echo "- TLS encryption"
echo "- client certificate authentication"
echo "- authorized producer access"
echo "- authorized consumer access"
echo "- exact message delivery"
echo "- least-privilege ACL denial"
echo "- no credential values printed"
echo "- ephemeral test workload cleanup"
