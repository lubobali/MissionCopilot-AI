"""Browser and host protections (threat model T41). Only the configured dashboard origin may call
the API from a browser, requests for unknown host names are refused, and every response, errors
and rate-limit answers included, carries the security headers."""

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

DASHBOARD = "https://dashboard.example.org"
HEADERS = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
}


def client(**settings) -> TestClient:
    return local_client(create_app(Settings(allowed_origins=(DASHBOARD,), **settings)))


@pytest.mark.parametrize(
    ("path", "status"), [("/v1/health", 200), ("/v1/nothing", 404), ("/docs", 404)]
)
def test_every_response_carries_the_security_headers(path, status):
    response = client().get(path)

    assert response.status_code == status
    assert {name: response.headers.get(name) for name in HEADERS} == HEADERS


def test_rate_limited_answers_carry_them_too():
    c = client(rate_limit_per_minute=1)
    c.get("/v1/health")

    response = c.get("/v1/health")

    assert response.status_code == 429
    assert response.headers["x-content-type-options"] == "nosniff"


def test_production_forces_https_for_two_years():
    hsts = client().get("/v1/health").headers["strict-transport-security"]

    assert hsts == "max-age=63072000; includeSubDomains"


def test_development_docs_pages_still_render():
    response = client(environment="development").get("/docs")

    assert response.status_code == 200
    assert "content-security-policy" not in response.headers  # the docs page needs its scripts


def test_the_dashboard_origin_may_call_from_a_browser():
    response = client().get("/v1/health", headers={"Origin": DASHBOARD})

    assert response.headers["access-control-allow-origin"] == DASHBOARD
    assert "access-control-allow-credentials" not in response.headers  # bearer tokens, no cookies


@pytest.mark.parametrize(
    "origin", ["https://evil.example", "null", "https://dashboard.example.org.evil"]
)
def test_other_origins_get_no_browser_access(origin):
    simple = client().get("/v1/health", headers={"Origin": origin})
    preflight = client().options(
        "/v1/health",
        headers={"Origin": origin, "Access-Control-Request-Method": "GET"},
    )

    assert "access-control-allow-origin" not in simple.headers
    assert "access-control-allow-origin" not in preflight.headers


def test_a_wildcard_origin_is_refused_at_start():
    with pytest.raises(ValueError, match="origin"):
        Settings(allowed_origins=("*",))


def test_an_unknown_host_name_is_refused():
    response = client().get("/v1/health", headers={"Host": "evil.example"})

    assert response.status_code == 400


def test_hosts_and_origins_come_from_the_environment():
    settings = Settings.from_env(
        {
            "MISSIONCOPILOT_ALLOWED_HOSTS": "api.example.org, localhost",
            "MISSIONCOPILOT_ALLOWED_ORIGINS": DASHBOARD,
        }
    )

    assert settings.allowed_hosts == ("api.example.org", "localhost")
    assert settings.allowed_origins == (DASHBOARD,)
