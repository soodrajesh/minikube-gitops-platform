import os
import time

import requests
from flask import Flask, Response
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

START_TIME = time.time()
REQUEST_COUNT = Counter(
    "sample_app_requests_total", "Total HTTP requests", ["path"]
)

GREETER_URL = os.environ.get("GREETER_URL", "http://greeter.backend.svc.cluster.local")


@app.route("/")
def hello():
    REQUEST_COUNT.labels(path="/").inc()
    return {
        "message": "hello from minikube-gitops-platform",
        "pod": os.environ.get("HOSTNAME", "unknown"),
    }


@app.route("/greeting")
def greeting():
    REQUEST_COUNT.labels(path="/greeting").inc()
    try:
        resp = requests.get(f"{GREETER_URL}/greet", timeout=2)
        resp.raise_for_status()
        return {"from": "greeter", **resp.json()}
    except requests.RequestException as exc:
        return {"error": f"could not reach greeter: {exc}"}, 502


@app.route("/health")
def health():
    REQUEST_COUNT.labels(path="/health").inc()
    return {
        "status": "ok",
        "uptime_seconds": round(time.time() - START_TIME, 1),
        # Confirms the secret was actually decrypted and mounted -- never the value itself.
        "api_key_configured": bool(os.environ.get("API_KEY")),
    }


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
