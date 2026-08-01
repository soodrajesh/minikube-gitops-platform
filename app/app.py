import os
import time

from flask import Flask, Response
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

START_TIME = time.time()
REQUEST_COUNT = Counter(
    "sample_app_requests_total", "Total HTTP requests", ["path"]
)


@app.route("/")
def hello():
    REQUEST_COUNT.labels(path="/").inc()
    return {
        "message": "hello from minikube-gitops-platform",
        "pod": os.environ.get("HOSTNAME", "unknown"),
    }


@app.route("/health")
def health():
    REQUEST_COUNT.labels(path="/health").inc()
    return {"status": "ok", "uptime_seconds": round(time.time() - START_TIME, 1)}


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
