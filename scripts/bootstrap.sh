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

echo "==> Building sample-app and greeter images inside minikube's docker daemon"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t sample-app:local "$(dirname "$0")/../app"
docker build -t greeter:local "$(dirname "$0")/../greeter"

echo "==> Adding argo, prometheus-community, gatekeeper, jetstack, and sealed-secrets helm repos"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null
helm repo update >/dev/null

# kube-prometheus-stack's CRDs are large enough that ArgoCD's client-side apply of
# them exceeds Kubernetes' 262144-byte metadata.annotations limit. Install them
# once here via true server-side apply (crds.enabled: false in monitoring/values.yaml
# stops the Helm release itself from trying to manage them through ArgoCD).
KPS_VERSION="62.7.0"
echo "==> Installing kube-prometheus-stack CRDs ($KPS_VERSION) via server-side apply"
KPS_DIR="$(mktemp -d)"
helm pull prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" --untar --untardir "$KPS_DIR"
kubectl apply --server-side --force-conflicts -f "$KPS_DIR/kube-prometheus-stack/charts/crds/crds/"
rm -rf "$KPS_DIR"

echo "==> Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 5m

echo "==> Installing Gatekeeper"
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --set replicas=1 \
  --set audit.replicas=1 \
  --wait --timeout 5m

echo "==> Installing cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set replicaCount=1 \
  --set webhook.replicaCount=1 \
  --set cainjector.replicaCount=1 \
  --wait --timeout 5m

echo "==> Installing Sealed Secrets"
# The controller's signing key must survive cluster rebuilds, or every SealedSecret
# already committed to git becomes permanently undecryptable (sealed against a key
# that no longer exists). Back it up outside the repo and restore it before the
# controller starts, so re-running bootstrap.sh after `minikube delete` keeps
# gitops/sample-app/sealed-secret.yaml valid instead of breaking it.
SEALED_SECRETS_KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-$HOME/.minikube-gitops-platform/sealed-secrets-key.yaml}"
mkdir -p "$(dirname "$SEALED_SECRETS_KEY_BACKUP")"
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
if [ -f "$SEALED_SECRETS_KEY_BACKUP" ]; then
  echo "    restoring previously backed-up sealing key from $SEALED_SECRETS_KEY_BACKUP"
  kubectl apply -f "$SEALED_SECRETS_KEY_BACKUP"
else
  echo "    no backed-up sealing key found; controller will generate a new one"
fi
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets \
  --wait --timeout 5m
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > "$SEALED_SECRETS_KEY_BACKUP"
echo "    sealing key backed up to $SEALED_SECRETS_KEY_BACKUP"

echo "==> ArgoCD installed. Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
echo "==> Run 'kubectl -n argocd port-forward svc/argocd-server 8080:80' to reach the UI."
