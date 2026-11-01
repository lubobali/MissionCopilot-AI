"""Authentication (threat model T30, T31): every route except health needs a valid signed token, the
organization comes only from that token, and every way a token can be wrong gets the same 401."""

import base64
import hashlib
import hmac
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.auth import Principal, TokenVerifier, require_principal, secured_router
from missioncopilot_backend.settings import Settings
from tests.unit.route_listing import served_routes

pytestmark = pytest.mark.unit

ISSUER = "https://login.example.org"
AUDIENCE = "missioncopilot-api"
PUBLIC_ROUTES = {"/v1/health"}


def pem(key: ec.EllipticCurvePrivateKey) -> str:
    return (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def token(signer, **changes) -> str:
    now = int(time.time())
    claims: dict[str, object] = {"iss": ISSUER, "aud": AUDIENCE, "sub": "officer-1", "org": "org-a"}
    claims |= {"iat": now, "exp": now + 300}
    claims |= changes
    return jwt.encode({k: v for k, v in claims.items() if v is not None}, signer, algorithm="ES256")


def build_app(verifier: TokenVerifier | None) -> FastAPI:
    app = create_app(Settings(), verifier=verifier)
    router = secured_router()

    @router.get("/me")
    def me(principal: Principal = Depends(require_principal)) -> dict[str, str]:
        return {"org": principal.org_id, "user": principal.user_id}

    @router.get("/status")
    def status() -> dict[str, str]:  # asks for no principal: only the router protects it
        return {"status": "secret"}

    app.include_router(router)
    return app


@pytest.fixture
def client(signer) -> TestClient:
    return TestClient(build_app(TokenVerifier(pem(signer), issuer=ISSUER, audience=AUDIENCE)))


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64_json(value: dict) -> str:
    return b64(json.dumps(value).encode())


def bearer(value: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {value}"}


def test_a_valid_token_names_the_organization(client, signer):
    response = client.get("/v1/me", headers=bearer(token(signer)))

    assert response.json() == {"org": "org-a", "user": "officer-1"}


def test_the_organization_comes_only_from_the_token(client, signer):
    headers = bearer(token(signer)) | {"X-Org": "org-b"}

    response = client.get("/v1/me", params={"org": "org-b"}, headers=headers)

    assert response.json()["org"] == "org-a"


def bad_tokens(signer) -> dict[str, dict[str, str]]:
    other = ec.generate_private_key(ec.SECP256R1())
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": "x",
        "org": "org-a",
        "iat": now,
        "exp": now + 300,
    }
    unsigned = f"{b64_json({'alg': 'none', 'typ': 'JWT'})}.{b64_json(claims)}."
    return {
        "no header": {},
        "not bearer": {"Authorization": "Basic b2ZmaWNlcjpwYXNz"},
        "valid token, wrong scheme": {"Authorization": f"Basic {token(signer)}"},
        "empty bearer": {"Authorization": "Bearer "},
        "garbage": bearer("not.a.token"),
        "expired": bearer(token(signer, iat=now - 600, exp=now - 300)),
        "wrong issuer": bearer(token(signer, iss="https://evil.example")),
        "wrong audience": bearer(token(signer, aud="another-api")),
        "other key": bearer(token(other)),
        "alg none": bearer(unsigned),
        "no organization": bearer(token(signer, org=None)),
        "empty organization": bearer(token(signer, org="")),
        "no expiry": bearer(token(signer, exp=None)),
        "no subject": bearer(token(signer, sub=None)),
    }


def test_every_bad_token_gets_the_same_401(client, signer):
    answers = {}
    for name, headers in bad_tokens(signer).items():
        response = client.get("/v1/me", headers=headers)
        assert response.status_code == 401, name
        assert response.headers["www-authenticate"] == "Bearer", name
        answers[name] = response.json()

    assert len({str(body) for body in answers.values()}) == 1, (
        "a 401 must not say which check failed"
    )


def test_hmac_signed_with_the_public_key_is_refused(client, signer):
    # Algorithm confusion: an attacker signs HS256 using our public key text as the shared secret.
    # PyJWT will not build this token, so build it by hand, the way an attacker would.
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": "x",
        "org": "org-b",
        "iat": now,
        "exp": now + 300,
    }
    signing_input = f"{b64_json({'alg': 'HS256', 'typ': 'JWT'})}.{b64_json(claims)}"
    mac = hmac.new(pem(signer).encode(), signing_input.encode(), hashlib.sha256).digest()

    assert client.get("/v1/me", headers=bearer(f"{signing_input}.{b64(mac)}")).status_code == 401


def test_no_verifier_configured_refuses_everything(signer):
    client = TestClient(build_app(verifier=None))

    assert client.get("/v1/me", headers=bearer(token(signer))).status_code == 401


def unprotected_routes(app: FastAPI) -> list[str]:
    client = TestClient(app)
    found = []
    for route in served_routes(app):
        if route.path not in PUBLIC_ROUTES:
            path = route.path.replace("{", "").replace("}", "")
            if client.request(route.method, path).status_code != 401:
                found.append(f"{route.method} {route.path}")
    return found


def test_every_route_except_health_needs_a_token(signer):
    app = build_app(TokenVerifier(pem(signer), issuer=ISSUER, audience=AUDIENCE))

    paths = {route.path for route in served_routes(app)}
    assert {"/v1/me", "/v1/status"} <= paths, "the guard must see routes on included routers"
    assert unprotected_routes(app) == []


def test_the_route_guard_sees_an_open_route(signer):
    app = build_app(TokenVerifier(pem(signer), issuer=ISSUER, audience=AUDIENCE))

    @app.get("/v1/forgot-auth")
    def open_route() -> dict[str, str]:
        return {}

    assert unprotected_routes(app) == ["GET /v1/forgot-auth"]
