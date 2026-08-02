import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import app  # noqa: E402


def test_hello():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json()["message"].startswith("hello")


def test_health():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    # No API_KEY env var in this test environment; must report False, never leak a value.
    assert body["api_key_configured"] is False


def test_metrics():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"sample_app_requests_total" in resp.data


def test_greeting_fails_gracefully_when_greeter_unreachable():
    # No greeter service exists in this test environment; the endpoint should
    # report the failure instead of crashing.
    client = app.test_client()
    resp = client.get("/greeting")
    assert resp.status_code == 502
    assert "error" in resp.get_json()
