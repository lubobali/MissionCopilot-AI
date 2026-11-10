"""The dashboard's sign-in routes (#174, step 8.4.3): a manager registers a passkey from the invite
and gets a session cookie (__Host-, Secure, HttpOnly, SameSite=Strict); signs in again with the
passkey; signs out. Every POST must come from the dashboard's own origin. The organization, person
and roles come from the stored session, never from the browser. With no dashboard address set, none
of this exists (404)."""

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client
from tests.unit.soft_authenticator import SoftAuthenticator

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
SAME = {"Origin": ORIGIN}


@pytest.fixture
def world():
    store, log = DashboardMemory(), AuditLog()
    settings = Settings(environment="test", dashboard_origin=ORIGIN)
    app = create_app(settings, audit=log, dashboard=store)
    client = TestClient(app, base_url=ORIGIN)  # https: the Secure cookie is sent
    user = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    code, _ = store.issue_invite(user.id)
    return client, store, log, code, SoftAuthenticator("localhost", ORIGIN)


def register(world):
    client, _, _, code, key = world
    options = client.post("/v1/dashboard/register/options", json={"code": code}, headers=SAME)
    assert options.status_code == 200, options.text
    credential = key.create(options.text)
    return client.post(
        "/v1/dashboard/register/verify", json={"credential": credential}, headers=SAME
    )


def test_registering_signs_the_manager_in_with_a_strict_cookie(world):
    client, _, log, _, _ = world

    response = register(world)

    assert response.status_code == 201 and response.json() == {"name": "Amina Diallo"}
    cookie = response.headers["set-cookie"]
    assert cookie.startswith("__Host-mc_session=")
    for part in ("Secure", "HttpOnly", "SameSite=strict", "Path=/"):
        assert part.lower() in cookie.lower(), cookie
    assert client.get("/v1/dashboard/me").json() == {
        "name": "Amina Diallo", "org": "org-a", "user": "manager-1", "roles": ["manager"],
    }  # fmt: skip
    kinds = [e.kind for e in log.events()]
    assert "passkey_added" in kinds and "dashboard_signed_in" in kinds


def test_signing_in_again_with_the_passkey(world):
    client, _, _, _, key = world
    register(world)
    client.cookies.clear()
    assert client.get("/v1/dashboard/me").status_code == 401

    options = client.post("/v1/dashboard/sign-in/options", headers=SAME)
    credential = key.get(options.text)
    signed = client.post(
        "/v1/dashboard/sign-in/verify", json={"credential": credential}, headers=SAME
    )

    assert signed.status_code == 200 and client.get("/v1/dashboard/me").status_code == 200


def test_a_failed_sign_in_is_the_same_401_and_recorded(world):
    client, _, log, _, key = world
    register(world)
    client.cookies.clear()
    options = client.post("/v1/dashboard/sign-in/options", headers=SAME)
    credential = key.get(options.text, origin="https://evil.example.org")

    response = client.post("/v1/dashboard/sign-in/verify", json={"credential": credential},
                           headers=SAME)  # fmt: skip

    assert response.status_code == 401 and "set-cookie" not in response.headers
    assert "dashboard_sign_in_failed" in [e.kind for e in log.events()]


def test_signing_out_ends_the_session(world):
    client, _, _, _, _ = world
    register(world)
    token = client.cookies.get("__Host-mc_session")

    response = client.post("/v1/dashboard/sign-out", headers=SAME, follow_redirects=False)

    assert response.status_code == 303 and response.headers["location"] == "/dashboard/sign-in"
    client.cookies.set("__Host-mc_session", token or "")
    assert client.get("/v1/dashboard/me").status_code == 401, "the old cookie no longer works"


@pytest.mark.parametrize("origin", [None, "https://evil.example.org", "http://localhost"])
def test_a_post_from_anywhere_else_is_refused(world, origin):
    client, _, _, code, _ = world
    headers = {"Origin": origin} if origin else {}

    response = client.post("/v1/dashboard/register/options", json={"code": code}, headers=headers)

    assert response.status_code == 403


def test_a_used_or_wrong_invite_is_the_same_401(world):
    client, _, _, code, _ = world
    register(world)

    for tried in (code, "not-a-code"):
        assert client.post("/v1/dashboard/register/options", json={"code": tried},
                           headers=SAME).status_code == 401  # fmt: skip


def test_a_made_up_cookie_is_refused(world):
    client, _, _, _, _ = world
    client.cookies.set("__Host-mc_session", "made-up")

    assert client.get("/v1/dashboard/me").status_code == 401


def test_with_no_dashboard_address_there_is_no_dashboard():
    client = local_client(create_app(Settings(environment="test")))

    assert client.post("/v1/dashboard/sign-in/options", headers=SAME).status_code == 404


def test_the_dashboard_address_must_be_https_or_this_machine():
    with pytest.raises(ValueError, match="https"):
        Settings(environment="test", dashboard_origin="http://mc.example.org")
    assert Settings(environment="test", dashboard_origin="http://localhost:8110").dashboard_origin
