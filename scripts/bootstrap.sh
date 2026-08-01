#!/usr/bin/env bash
set -euo pipefail

CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6g}"
PROFILE="${MINIKUBE_PROFILE:-minikube}"

echo "==> Starting minikube (profile=$PROFILE, cpus=$CPUS, memory=$MEMORY)"
minikube start --profile "$PROFILE" --cpus "$CPUS" --memory "$MEMORY" --driver=docker

echo "==> Enabling addons: ingress, metrics-server"
minikube addons enable ingress --profile "$PROFILE"
minikube addons enable metrics-server --profile "$PROFILE"

echo "==> Building sample-app image inside minikube's docker daemon"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t sample-app:local "$(dirname "$0")/../app"

echo "==> Adding argo helm repo"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

echo "==> Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 5m

echo "==> ArgoCD installed. Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
echo "==> Run 'kubectl -n argocd port-forward svc/argocd-server 8080:80' to reach the UI."
