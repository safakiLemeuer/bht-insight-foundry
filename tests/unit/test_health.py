"""Tests for the public health endpoint."""

from fastapi.testclient import TestClient

from bht_insight.main import app

client = TestClient(app)


def test_health_returns_minimal_success_payload() -> None:
    """The health endpoint must return only non-sensitive status information."""
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}
