"""What the backend exposes (threat model T35, T37): in production the API docs pages are gone,
because they hand out a map of every route; and the app serves only contract routes."""

from pathlib import Path

import pytest
import yaml

from missioncopilot_backend.app import create_app
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client
from tests.unit.route_listing import served_routes

pytestmark = pytest.mark.unit

SPEC_PATH = Path(__file__).resolve().parents[3] / "docs" / "api" / "openapi.yaml"
DOCS_PAGES = ["/docs", "/redoc", "/openapi.json"]


@pytest.mark.parametrize("page", DOCS_PAGES)
def test_docs_pages_are_off_in_production(page):
    client = local_client(create_app(Settings(environment="production")))

    assert client.get(page).status_code == 404


@pytest.mark.parametrize("page", DOCS_PAGES)
def test_docs_pages_work_in_development(page):
    client = local_client(create_app(Settings(environment="development")))

    assert client.get(page).status_code == 200


def test_health_is_versioned_like_the_contract():
    client = local_client(create_app(Settings()))

    assert client.get("/v1/health").json() == {"status": "ok"}
    assert client.get("/health").status_code == 404


def test_every_route_is_in_the_contract():
    spec = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))
    contract = {(method.upper(), path) for path, item in spec["paths"].items() for method in item}
    served = {(route.method, route.path) for route in served_routes(create_app(Settings()))}

    assert ("GET", "/v1/health") in served, "the guard must see routes on included routers"
    assert served - contract == set()
