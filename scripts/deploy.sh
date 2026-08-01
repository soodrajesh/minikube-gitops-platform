#!/usr/bin/env bash
set -euo pipefail

ROOT_APP="$(dirname "$0")/../gitops/root-app.yaml"

echo "==> Applying root Application (app-of-apps)"
kubectl apply -f "$ROOT_APP"

echo "==> Waiting for child Applications to appear"
for i in $(seq 1 30); do
  count=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -ge 3 ]; then
    break
  fi
  sleep 5
done

echo "==> Waiting for all Applications to be Synced and Healthy (up to 10 min)"
for i in $(seq 1 60); do
  not_ready=$(kubectl get applications -n argocd -o json \
    | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name')
  if [ -z "$not_ready" ]; then
    echo "==> All Applications Synced/Healthy."
    kubectl get applications -n argocd
    exit 0
  fi
  echo "    still waiting on: $(echo "$not_ready" | tr '\n' ' ')"
  sleep 10
done

echo "!! Timed out waiting for Applications to become healthy" >&2
kubectl get applications -n argocd -o wide
exit 1
