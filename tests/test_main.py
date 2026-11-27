import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402

client = TestClient(app)


def test_root_returns_expected_payload():
    response = client.get("/")
    assert response.status_code == 200
    body = response.json()
    assert body["message"] == "Hello from DevOps Task!"
    assert body["status"] == "running"
    assert "version" in body


def test_health_returns_healthy():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_metrics_endpoint_exposes_prometheus_format():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "http_requests_total" in response.text
    assert "http_request_duration_seconds" in response.text


def test_request_count_increments_after_calls():
    before = client.get("/metrics").text.count("http_requests_total")
    client.get("/")
    client.get("/")
    after = client.get("/metrics").text.count("http_requests_total")
    assert after >= before


def test_not_found_route_returns_404():
    response = client.get("/does-not-exist")
    assert response.status_code == 404
