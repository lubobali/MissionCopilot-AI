"""The dashboard's first pages (#174, step 8.4.4): sign in, create your passkey from the invite, and
a home that needs a session. Pages are built on the server; their own content policy lets them load
only this server's script, styles and fonts; the API keeps its stricter one. Fonts ship with their
licences."""

from importlib.resources import files

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.headers import DASHBOARD_POLICY
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"


@pytest.fixture
def world():
    store = DashboardMemory()
    app = create_app(Settings(environment="test", dashboard_origin=ORIGIN), dashboard=store)
    return TestClient(app, base_url=ORIGIN), store


def test_the_sign_in_page_offers_touch_id(world):
    client, _ = world

    page = client.get("/dashboard/sign-in")

    assert page.status_code == 200 and page.headers["content-type"].startswith("text/html")
    assert "Sign in with Touch ID" in page.text and 'data-action="sign-in"' in page.text
    assert '<script src="/dashboard/static/dashboard.js" defer></script>' in page.text
    assert '<link rel="stylesheet" href="/dashboard/static/dashboard.css">' in page.text
    assert page.headers["content-security-policy"] == DASHBOARD_POLICY


def test_the_invite_page_carries_its_code_safely(world):
    client, _ = world

    page = client.get('/dashboard/invite/abc"<x>')

    assert "Create your passkey" in page.text
    assert 'data-code="abc&quot;&lt;x&gt;"' in page.text, "escaped, never raw"


def test_home_needs_a_session(world):
    client, store = world

    assert (
        client.get("/dashboard", follow_redirects=False).headers["location"] == "/dashboard/sign-in"
    )
    user = store.add_user("org-a", "manager-1", "Amina <Diallo>", ("manager",))
    client.cookies.set("__Host-mc_session", store.new_session(user.id))
    home = client.get("/dashboard")
    assert home.status_code == 200 and "Amina &lt;Diallo&gt;" in home.text
    assert 'action="/dashboard/sign-out"' not in home.text  # the API path, below
    assert 'action="/v1/dashboard/sign-out"' in home.text


def test_the_policy_allows_only_this_server(world):
    for part in ("default-src 'none'", "script-src 'self'", "style-src 'self'", "font-src 'self'",
                 "connect-src 'self'", "form-action 'self'", "base-uri 'none'",
                 "frame-ancestors 'none'"):  # fmt: skip
        assert part in DASHBOARD_POLICY
    assert "unsafe" not in DASHBOARD_POLICY and "http" not in DASHBOARD_POLICY


def test_the_api_keeps_its_own_policy(world):
    client, _ = world

    assert client.get("/v1/health").headers["content-security-policy"] == (
        "default-src 'none'; frame-ancestors 'none'"
    )


@pytest.mark.parametrize(
    ("path", "kind"),
    [("dashboard.js", "javascript"), ("dashboard.css", "text/css"),
     ("fonts/InterTight-latin-wght400-600.woff2", "font/woff2")],
)  # fmt: skip
def test_the_static_files_are_served(world, path, kind):
    client, _ = world

    response = client.get(f"/dashboard/static/{path}")

    assert response.status_code == 200 and kind in response.headers["content-type"]


def test_the_fonts_ship_with_their_licences():
    fonts = files("missioncopilot_backend") / "dashboard_static" / "fonts"
    for name in ("InterTight", "Fraunces", "JetBrainsMono"):
        assert (fonts / f"{name}-OFL.txt").read_text().find("SIL Open Font License") >= 0


def test_with_no_dashboard_address_there_are_no_pages():
    client = local_client(create_app(Settings(environment="test")))

    assert client.get("/dashboard/sign-in").status_code == 404


def test_dashboard_pages_send_their_origin_to_this_site_only(world):
    """Found on staging (#174): with Referrer-Policy no-referrer a browser sends Origin: null on a
    plain form POST (the Sign out button), so the Origin check refused it (403). Dashboard pages say
    same-origin: the browser sends the origin to this site and nothing to any other."""
    client, _ = world

    assert client.get("/dashboard/sign-in").headers["referrer-policy"] == "same-origin"
    assert client.get("/v1/health").headers["referrer-policy"] == "no-referrer", "the API keeps it"


@pytest.mark.parametrize(("path", "kind"), [("fonts/Fraunces-latin-400.woff2", "font/woff2"),
                                            ("logo.png", "image/png")])  # fmt: skip
def test_fonts_and_the_logo_have_their_own_types(world, path, kind):
    """Found on staging: a slim server image has no woff2 type: fonts went out as octet-stream."""
    client, _ = world

    assert client.get(f"/dashboard/static/{path}").headers["content-type"] == kind


def test_the_brand_is_the_apps_logo_trail_and_airplane(world):
    client, _ = world

    page = client.get("/dashboard/sign-in").text

    assert (
        '<img class="logo" src="/dashboard/static/logo.png" alt="" width="36" height="38">' in page
    )
    assert 'class="trail"' in page and 'class="plane"' in page
