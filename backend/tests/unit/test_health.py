import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import app

pytestmark = pytest.mark.unit


def test_health_returns_ok():
    client = TestClient(app)

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
