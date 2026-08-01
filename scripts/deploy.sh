#!/usr/bin/env bash
set -euo pipefail

ROOT_APP="$(dirname "$0")/../gitops/root-app.yaml"

echo "==> Applying root Application (app-of-apps)"
kubectl apply -f "$ROOT_APP"

echo "==> Waiting for child Applications to appear"
kubectl wait --for=create application/root-app -n argocd --timeout=60s
until kubectl get application sample-app kube-prometheus-stack -n argocd >/dev/null 2>&1; do
  sleep 2
done

echo "==> Waiting for all Applications to be Synced and Healthy"
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
  --for=jsonpath='{.status.health.status}'=Healthy \
  application --all -n argocd --timeout=600s

kubectl get applications -n argocd
