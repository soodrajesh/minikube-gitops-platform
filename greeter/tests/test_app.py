import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import app, GREETINGS  # noqa: E402


def test_greet():
    client = app.test_client()
    resp = client.get("/greet")
    assert resp.status_code == 200
    assert resp.get_json()["greeting"] in GREETINGS


def test_health():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_metrics():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"greeter_requests_total" in resp.data
