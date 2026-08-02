#!/usr/bin/env bash
# Generates CPU load against sample-app from inside the cluster (bypasses ingress/port-forward
# entirely, so it isn't bottlenecked by your laptop's network stack) and watches the HPA react.
set -euo pipefail

DURATION="${1:-90}"
JOB_NAME="sample-app-load-test"

echo "==> Starting HPA and current replica count"
kubectl get hpa -n app sample-app
kubectl get pods -n app -l app=sample-app --no-headers | wc -l | xargs echo "current replicas:"

echo "==> Launching load-generating Job ($DURATION seconds, 4 parallel workers)"
kubectl delete job "$JOB_NAME" -n app --ignore-not-found >/dev/null 2>&1
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: app
spec:
  parallelism: 4
  backoffLimit: 0
  activeDeadlineSeconds: $((DURATION + 30))
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.10.1
          command:
            - sh
            - -c
            - |
              end=\$(( \$(date +%s) + $DURATION ))
              while [ \$(date +%s) -lt \$end ]; do
                curl -s -o /dev/null http://sample-app.app.svc.cluster.local/
              done
EOF

echo "==> Watching HPA for $((DURATION + 30))s (Ctrl-C to stop watching; the Job keeps running)"
kubectl get hpa -n app sample-app -w &
WATCH_PID=$!
sleep "$((DURATION + 30))"
kill "$WATCH_PID" 2>/dev/null || true

echo
echo "==> Final state"
kubectl get hpa -n app sample-app
kubectl get pods -n app -l app=sample-app

echo
echo "==> Cleaning up the load-test Job"
kubectl delete job "$JOB_NAME" -n app --ignore-not-found

echo "==> Note: scale-down takes a few minutes (stabilizationWindowSeconds: 60 in hpa.yaml, plus"
echo "    metrics-server's own scrape interval) -- watch it settle with: kubectl get hpa -n app -w"
