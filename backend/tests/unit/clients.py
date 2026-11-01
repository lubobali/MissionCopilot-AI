"""A test client that calls the app as a real allowed host (localhost), so tests run with the
host check on, exactly as production does."""

from fastapi.testclient import TestClient
from starlette.types import ASGIApp


def local_client(app: ASGIApp, **kwargs) -> TestClient:
    return TestClient(app, base_url="http://localhost", **kwargs)
