"""Roles (threat model T26, API5:2023 broken function-level authorization). Roles come only from the
token; an action a role does not allow answers 403 and is recorded; no token is still 401."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.auth import Principal, TokenVerifier, require_role, secured_router
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

ISSUER, AUDIENCE = "https://login.example.org", "missioncopilot-api"


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def headers(signer, roles: object = None) -> dict[str, str]:
    now = int(time.time())
    claims: dict[str, object] = {"iss": ISSUER, "aud": AUDIENCE, "sub": "u1", "org": "org-a"}
    claims |= {"iat": now, "exp": now + 300}
    if roles is not None:
        claims["roles"] = roles
    return {"Authorization": f"Bearer {jwt.encode(claims, signer, algorithm='ES256')}"}


def build_app(signer, log: AuditLog) -> FastAPI:
    public = signer.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    verifier = TokenVerifier(public.decode(), issuer=ISSUER, audience=AUDIENCE)
    app = create_app(Settings(), verifier=verifier, audit=log)
    router = secured_router()

    @router.post("/test/approve")
    def approve(principal: Principal = Depends(require_role("manager"))) -> dict[str, list[str]]:
        return {"roles": sorted(principal.roles)}

    @router.post("/test/codes")
    def codes(principal: Principal = Depends(require_role("admin"))) -> dict[str, str]:
        return {"by": principal.user_id}

    app.include_router(router)
    return app


@pytest.fixture
def log() -> AuditLog:
    return AuditLog()


@pytest.fixture
def client(signer, log):
    return local_client(build_app(signer, log))


def test_a_manager_may_approve(client, signer):
    response = client.post("/v1/test/approve", headers=headers(signer, ["manager"]))

    assert response.json() == {"roles": ["manager"]}


def test_a_role_the_action_does_not_allow_gets_403_and_is_recorded(client, signer, log):
    officer = client.post("/v1/test/approve", headers=headers(signer, ["officer"]))
    manager = client.post("/v1/test/codes", headers=headers(signer, ["manager"]))
    nobody = client.post("/v1/test/approve", headers=headers(signer))

    assert [officer.status_code, manager.status_code, nobody.status_code] == [403, 403, 403]
    assert officer.headers["content-type"] == "application/problem+json"
    assert [(e.kind, e.org_id, e.actor) for e in log.events()] == [
        ("role_denied", "org-a", "u1")
    ] * 3


def test_no_token_is_401_not_403(client):
    assert client.post("/v1/test/approve").status_code == 401


@pytest.mark.parametrize("roles", ["admin", [1, 2], {"admin": True}])
def test_roles_that_are_not_a_list_of_names_make_a_bad_token(client, signer, roles):
    assert client.post("/v1/test/codes", headers=headers(signer, roles)).status_code == 401
