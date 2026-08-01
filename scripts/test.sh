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
}
trap cleanup EXIT

echo "==> Port-forwarding ingress-nginx-controller"
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8888:80 >/tmp/ingress-pf.log 2>&1 &
INGRESS_PID=$!

check "sample-app /health returns 200" bash -c \
  "[ \"\$($CURL -o /dev/null -w '%{http_code}' -H 'Host: sample-app.local' http://localhost:8888/health)\" = '200' ]"

check "sample-app /metrics exposes custom counter" bash -c \
  "$CURL -H 'Host: sample-app.local' http://localhost:8888/metrics | grep -q sample_app_requests_total"

echo "==> Port-forwarding Prometheus to check sample-app target"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/prom-pf.log 2>&1 &
PROM_PID=$!
check "Prometheus has an up target for sample-app" bash -c \
  "$CURL http://localhost:9090/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job==\"sample-app\" and .health==\"up\")' >/dev/null"
kill "$PROM_PID" 2>/dev/null || true

echo "==> Port-forwarding Grafana to check health"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/tmp/grafana-pf.log 2>&1 &
GRAFANA_PID=$!
check "Grafana /api/health returns 200" bash -c \
  "[ \"\$($CURL -o /dev/null -w '%{http_code}' http://localhost:3000/api/health)\" = '200' ]"
kill "$GRAFANA_PID" 2>/dev/null || true

check "default-deny NetworkPolicy exists in app namespace" bash -c \
  "kubectl get networkpolicy -n app default-deny-ingress >/dev/null 2>&1"

if [ "$FAIL" -ne 0 ]; then
  echo "==> One or more checks FAILED"
  exit 1
fi
echo "==> All smoke tests passed"
