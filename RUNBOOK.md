# Runbook

Step-by-step commands to spin this up yourself, verify it's actually working, poke around the
UIs, and tear it down. Everything here assumes you're in the repo root
(`minikube-gitops-platform/`).

Your cluster is currently already running from my earlier verification pass — you can skip
straight to **2. Verify it's healthy** if you just want to look around, or start at **1** if you
want to rebuild from scratch.

## 0. Prerequisites

```bash
minikube version   # tested with v1.36.0
kubectl version --client   # tested with v1.33.4
helm version --short       # tested with v3.18.5
docker --version           # tested with 27.3.1
jq --version                # used by scripts/deploy.sh
```

## 1. Spin it up

```bash
./scripts/bootstrap.sh
```

What this does, in order: starts minikube (4 CPU / 6GB by default — override with
`MINIKUBE_CPUS`/`MINIKUBE_MEMORY` env vars), enables the `ingress` and `metrics-server` addons,
builds both apps' Docker images directly into minikube's Docker daemon, installs the
prometheus-operator CRDs via `kubectl apply --server-side` (see "Why server-side apply" in
SECURITY.md/README if curious why that's a separate step), then installs ArgoCD and Gatekeeper
via Helm.

At the end it prints ArgoCD's admin password. If you need it again later:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Then apply the GitOps root Application and wait for ArgoCD to sync everything:

```bash
./scripts/deploy.sh
```

This should end with a table showing `sample-app`, `greeter`, `kube-prometheus-stack`,
`policy-templates`, `policy-constraints`, and `root-app` all `Synced` / `Healthy`. Note:
`policy-constraints` may show a transient `SyncFailed`/`OutOfSync` on the very first deploy —
it needs `policy-templates`' CRDs to exist first, and ArgoCD's automated `selfHeal` retries it
with backoff until they do (usually resolves within a couple of minutes). If it's still failing
after that, see **Troubleshooting** below.

## 2. Verify it's healthy

Automated version (does everything below for you, with real pass/fail output):

```bash
./scripts/test.sh
```

If you want to check things by hand instead:

```bash
# All five Applications should show Synced / Healthy
kubectl get applications -n argocd

# Pods in every namespace should be Running
kubectl get pods -n app
kubectl get pods -n backend
kubectl get pods -n monitoring
kubectl get pods -n gatekeeper-system

# The NetworkPolicies are actually in place
kubectl get networkpolicy -n app
kubectl get networkpolicy -n backend

# sample-app can actually reach greeter (through the ingress path, same as test.sh)
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8888:80 &
curl -H "Host: sample-app.local" http://localhost:8888/greeting
kill %1
```

## 2b. Confirm Gatekeeper is actually enforcing something

The best way to see policy-as-code do something is to watch it reject a bad pod. Try creating an
obviously non-compliant one in the `app` namespace:

```bash
kubectl run bad-pod -n app --image=nginx:latest --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"bad-pod","image":"nginx:latest"}]}}'
```

Expect an admission error mentioning both the missing `runAsNonRoot`/resources and the
`:latest` tag — Gatekeeper blocked it before it was ever scheduled. The same command against the
`default` namespace (not covered by the Constraints) would succeed, which is the intended
scoping — see README for why.

## 3. Look around the UIs

**The app itself** (through the same ingress path `test.sh` uses):

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8888:80
# in another terminal:
curl -H "Host: sample-app.local" http://localhost:8888/
curl -H "Host: sample-app.local" http://localhost:8888/health
curl -H "Host: sample-app.local" http://localhost:8888/metrics
```

**ArgoCD UI** — see the app-of-apps tree, sync history, live diffs:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open http://localhost:8080 (`bootstrap.sh` installs ArgoCD with `server.insecure=true`, so it's
plain HTTP here — port 443 on the Service is TLS-terminated by the same insecure backend and
won't complete a TLS handshake, so use port 80). Login: `admin` / the password from step 1.

**Grafana** — dashboards, the sample app's metrics:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open http://localhost:3000. Login: `admin` / (fetch the password):

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

**Prometheus** — raw targets/metrics, confirm the app is being scraped:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090/targets — you should see `sample-app` and `greeter` targets with
state `UP`. (`greeter` has no ingress of its own — it's internal-only, reached through
`sample-app`'s `/greeting` endpoint or Prometheus's scrape, both from inside the cluster.)

## 4. Try the GitOps loop yourself

Make a small change (e.g. edit the message string in `app/app.py`, or bump `replicas` in
`gitops/sample-app/deployment.yaml`), commit, and push to `main`. Within ~3 minutes (ArgoCD's
default polling interval) it should auto-sync without you touching kubectl. To watch it happen
live instead of waiting:

```bash
kubectl patch application sample-app -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl get applications -n argocd -w
```

Note: if you change `app/app.py` or the `Dockerfile`, you also need to rebuild the image into
minikube's Docker daemon before ArgoCD's sync will show the new behavior — ArgoCD only manages
the Kubernetes manifests, not the image build:

```bash
eval "$(minikube docker-env)"
docker build -t sample-app:local app/
kubectl rollout restart deployment/sample-app -n app
```

## 5. Tear down

```bash
./scripts/teardown.sh
```

Asks for confirmation, then runs `minikube delete`. This destroys the cluster entirely —
everything is reproducible from this repo, so that's expected and fine.

## Troubleshooting

**`kube-prometheus-stack` Application stuck `OutOfSync` with a `metadata.annotations: Too long`
error** — this means the CRDs weren't installed via server-side apply first (should already be
handled by `bootstrap.sh`, but if you ever install the chart's CRDs manually via plain
`kubectl apply`, this comes back). Fix:

```bash
KPS_DIR=$(mktemp -d)
helm pull prometheus-community/kube-prometheus-stack --version 62.7.0 --untar --untardir "$KPS_DIR"
kubectl apply --server-side --force-conflicts -f "$KPS_DIR/kube-prometheus-stack/charts/crds/crds/"
```

**`policy-constraints` stuck failing with `the server could not find the requested resource` /
`failed to discover server resources for group version constraints.gatekeeper.sh/v1beta1`** —
its Constraint CRDs are generated by `policy-templates`' ConstraintTemplates, which may not have
finished reconciling yet. Force both to refresh:

```bash
kubectl patch application policy-templates policy-constraints -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

If it's been more than a few minutes, check the ConstraintTemplates actually exist and Gatekeeper
is running: `kubectl get constrainttemplates`, `kubectl get pods -n gatekeeper-system`.

**Pods flapping / random `NodeNotReady` / DNS or TLS timeouts everywhere** — the minikube VM ran
out of memory. Check actual usage: `docker stats --no-stream minikube`. If it's pinned near its
limit, minikube likely reused an old cluster's memory setting rather than the `--memory` flag you
passed (minikube silently ignores `--memory`/`--cpus` on an existing cluster — it only applies on
creation). Fix: `minikube delete` then `./scripts/bootstrap.sh` again.

**`curl` to `minikube ip` hangs forever** — expected on macOS/Windows with the Docker driver;
that IP isn't routable from the host. Use the `kubectl port-forward` approach in step 3 instead.

**An Application shows `Unknown` sync status with a `ComparisonError` mentioning a CRD kind**
(e.g. `unable to resolve parseableType for ... Kind=Alertmanager`) — ArgoCD's cached API schema
is stale, usually right after CRDs were reinstalled. Force it to refresh:

```bash
kubectl patch application kube-prometheus-stack -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```
