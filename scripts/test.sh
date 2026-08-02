#!/usr/bin/env bash
set -euo pipefail

FAIL=0
CURL="curl -s --retry 10 --retry-connrefused --retry-delay 2 --max-time 5"

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAIL=1
  fi
}

cleanup() {
  [ -n "${INGRESS_PID:-}" ] && kill "$INGRESS_PID" 2>/dev/null || true
  [ -n "${PROM_PID:-}" ] && kill "$PROM_PID" 2>/dev/null || true
  [ -n "${GRAFANA_PID:-}" ] && kill "$GRAFANA_PID" 2>/dev/null || true
  [ -n "${CA_CERT:-}" ] && rm -f "$CA_CERT"
}
trap cleanup EXIT

echo "==> Fetching the local CA cert (cert-manager) to verify TLS against"
CA_CERT="$(mktemp)"
kubectl get secret local-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_CERT"

echo "==> Port-forwarding ingress-nginx-controller (TLS: ingress now redirects plain HTTP to HTTPS)"
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8443:443 >/tmp/ingress-pf.log 2>&1 &
INGRESS_PID=$!
HTTPS_CURL="$CURL --cacert $CA_CERT --resolve sample-app.local:8443:127.0.0.1"

check "sample-app /health returns 200 over TLS, verified against the local CA" bash -c \
  "[ \"\$($HTTPS_CURL -o /dev/null -w '%{http_code}' https://sample-app.local:8443/health)\" = '200' ]"

check "sample-app /metrics exposes custom counter" bash -c \
  "$HTTPS_CURL https://sample-app.local:8443/metrics | grep -q sample_app_requests_total"

check "sample-app /greeting reaches greeter across namespaces" bash -c \
  "$HTTPS_CURL https://sample-app.local:8443/greeting | jq -e '.greeting' >/dev/null"

check "sample-app decrypted its SealedSecret (api_key_configured: true)" bash -c \
  "$HTTPS_CURL https://sample-app.local:8443/health | jq -e '.api_key_configured == true' >/dev/null"

echo "==> Port-forwarding Prometheus to check sample-app and greeter targets"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/prom-pf.log 2>&1 &
PROM_PID=$!
check "Prometheus has an up target for sample-app" bash -c \
  "$CURL http://localhost:9090/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"sample-app\" and .health==\"up\")' >/dev/null"
check "Prometheus has an up target for greeter" bash -c \
  "$CURL http://localhost:9090/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"greeter\" and .health==\"up\")' >/dev/null"
kill "$PROM_PID" 2>/dev/null || true

echo "==> Port-forwarding Grafana to check health"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/tmp/grafana-pf.log 2>&1 &
GRAFANA_PID=$!
check "Grafana /api/health returns 200" bash -c \
  "[ \"\$($CURL -o /dev/null -w '%{http_code}' http://localhost:3000/api/health)\" = '200' ]"
kill "$GRAFANA_PID" 2>/dev/null || true

GRAFANA_HTTPS_CURL="$CURL --cacert $CA_CERT --resolve grafana.local:8443:127.0.0.1"
check "Grafana /api/health returns 200 over TLS through ingress, verified against the local CA" bash -c \
  "[ \"\$($GRAFANA_HTTPS_CURL -o /dev/null -w '%{http_code}' https://grafana.local:8443/api/health)\" = '200' ]"

check "default-deny NetworkPolicy exists in app namespace" bash -c \
  "kubectl get networkpolicy -n app default-deny-ingress >/dev/null 2>&1"

check "default-deny NetworkPolicy exists in backend namespace" bash -c \
  "kubectl get networkpolicy -n backend default-deny-ingress >/dev/null 2>&1"

check "Gatekeeper blocks a non-compliant pod in the app namespace" bash -c \
  "! kubectl run gatekeeper-smoke-test -n app --image=nginx:latest --restart=Never --dry-run=server >/dev/null 2>&1"

check "sample-app's HPA is computing a real CPU metric (not <unknown>)" bash -c \
  "kubectl get hpa -n app sample-app -o jsonpath='{.status.currentMetrics}' | grep -q averageUtilization"
echo "    (this only checks the HPA object and metrics-server are wired up correctly --"
echo "     for an actual scale-up under load, run ./scripts/load-test.sh)"

if [ "$FAIL" -ne 0 ]; then
  echo "==> One or more checks FAILED"
  exit 1
fi
echo "==> All smoke tests passed"
