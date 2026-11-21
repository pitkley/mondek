#!/usr/bin/env bash
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
set -eu

if [[ $# != 2 ]]; then
  echo "Usage: $0 CONTROLLER_IMAGE POSTGRES_IMAGE" >&2
  exit 2
fi

controller_image=$1
postgres_image=$2
docker image inspect "$controller_image" "$postgres_image" >/dev/null

fixture=$(mktemp -d "${TMPDIR:-/tmp}/mondek-webhook.XXXXXX")
cluster=$(basename "$fixture" | tr '[:upper:].' '[:lower:]-')
export KUBECONFIG="$fixture/kubeconfig"

cleanup() {
  local status=$?
  if [[ "$status" != 0 && -f "$KUBECONFIG" ]]; then
    kubectl get pods -o wide >&2 || true
    kubectl logs webhook-controller --tail=50 >&2 || true
  fi
  if ! kind delete cluster --name "$cluster"; then status=1; fi
  rm -rf -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --wait 120s \
  --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
kind load docker-image "$controller_image" "$postgres_image" --name "$cluster"

kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  containers:
    - name: postgres
      image: "$postgres_image"
      imagePullPolicy: Never
      env:
        - name: POSTGRES_USER
          value: "mondek"
        - name: POSTGRES_DB
          value: "mondek"
        - name: POSTGRES_PASSWORD
          value: "isolated-fixture-password"
      readinessProbe:
        exec:
          command: [pg_isready, -h, "127.0.0.1", -U, mondek, -d, mondek]
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
YAML
kubectl wait --for=condition=Ready pod/postgres --timeout=90s

kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: webhook-fixture
stringData:
  webhooks.json: |
    {"active":"ops","destinations":{"ops":{"url":"http://127.0.0.1:9/fixture"}}}
---
apiVersion: v1
kind: Pod
metadata:
  name: webhook-controller
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65533
  containers:
    - name: controller
      image: "$controller_image"
      imagePullPolicy: Never
      env:
        - name: MONDEK_DEPLOYMENT_MODE
          value: "true"
        - name: MONDEK_PUBLIC_URL
          value: "https://mondek.example.invalid"
        - name: MONDEK_BIND_ADDRESS
          value: "0.0.0.0"
        - name: SECRET_KEY_BASE
          value: "a-synthetic-fake-secret-signing-key-for-this-isolated-test-only-000000"
        - name: PGHOST
          value: "postgres"
        - name: PGUSER
          value: "mondek"
        - name: PGDATABASE
          value: "mondek"
        - name: PGPASSWORD
          value: "isolated-fixture-password"
        - name: MONDEK_NOTIFICATION_ADAPTER
          value: "webhook"
        - name: MONDEK_WEBHOOK_CONFIG_FILE
          value: "/run/secrets/mondek/webhooks.json"
        - name: MONDEK_WEBHOOK_CONFIG_GROUP_ID
          value: "65533"
      readinessProbe:
        httpGet:
          path: /health
          port: 4000
      volumeMounts:
        - name: webhook
          mountPath: /run/secrets/mondek
          readOnly: true
  volumes:
    - name: webhook
      secret:
        secretName: webhook-fixture
        defaultMode: 0440
YAML
kubectl wait --for=condition=Ready pod/webhook-controller --timeout=120s
kubectl exec -i webhook-controller -- sh -eu <<'CHECK'
  file=/run/secrets/mondek/webhooks.json
  test "$(id -u)" = 65532
  case " $(id -G) " in *" 65533 "*) ;; *) exit 1 ;; esac
  test -L "$file"
  test "$(stat -Lc "%a %u %g" "$file")" = "440 0 65533"
  curl -fsS http://127.0.0.1:4000/health >/dev/null
CHECK
echo 'The non-root controller is ready with a projected webhook Secret.'
