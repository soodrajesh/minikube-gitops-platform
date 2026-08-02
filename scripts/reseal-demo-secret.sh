#!/usr/bin/env bash
# Regenerates gitops/sample-app/sealed-secret.yaml against whatever cluster your kubeconfig
# currently points at. You need this after a fresh `minikube delete` if the sealing key backup
# (scripts/bootstrap.sh's SEALED_SECRETS_KEY_BACKUP) was lost or you're pointing at a different
# cluster than the one the committed sealed-secret.yaml was sealed for -- the committed one will
# fail to decrypt anywhere else. Also use this to rotate the demo API key value.
set -euo pipefail

API_KEY_VALUE="${1:-demo-api-key-not-a-real-secret}"
OUT="$(dirname "$0")/../gitops/sample-app/sealed-secret.yaml"

kubectl create secret generic sample-app-secret -n app \
  --from-literal=api-key="$API_KEY_VALUE" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml \
  > "$OUT"

echo "Wrote $OUT. Review it, then commit and push -- ArgoCD will pick it up."
