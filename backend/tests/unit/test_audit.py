"""Audit log of security events (threat model T38). Append-only and hash-chained: a changed or
removed entry is found by verify(). It records who, what, when and from where, never tokens or
request bodies, and a stream of refused requests records when blocking starts, not every refusal."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI, Request

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import GENESIS, AuditLog
from missioncopilot_backend.auth import TokenVerifier, secured_router
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.tenancy import MissionStore, OrgDatabases, org_store
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

ISSUER, AUDIENCE = "https://login.example.org", "missioncopilot-api"


def test_each_entry_is_chained_to_the_one_before():
    log = AuditLog(clock=lambda: 1000.0)
    first = log.record("auth_failed", client="1.2.3.4")
    second = log.record("rate_limited", client="1.2.3.4")

    assert first.prev_hash == GENESIS
    assert second.prev_hash == first.hash
    assert log.head() == second.hash
    assert log.verify() == []


def test_a_changed_entry_is_found():
    log = AuditLog(clock=lambda: 1000.0)
    for n in range(3):
        log.record("auth_failed", client=f"10.0.0.{n}")

    log._events[1] = log._events[1].replace(client="10.9.9.9")  # an attacker edits the store

    assert log.verify() == ["entry 1 was changed"]


def test_a_removed_entry_is_found():
    log = AuditLog(clock=lambda: 1000.0)
    for n in range(3):
        log.record("auth_failed", client=f"10.0.0.{n}")

    del log._events[1]

    assert log.verify() == ["entry 1 does not follow entry 0"]


def test_the_log_can_only_grow():
    log = AuditLog()
    log.record("auth_failed", client="1.2.3.4")

    assert isinstance(log.events(), tuple)
    assert not any(hasattr(log, name) for name in ("update", "delete", "remove", "clear", "pop"))


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def build_app(signer, log: AuditLog, **settings) -> FastAPI:
    public = signer.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    verifier = TokenVerifier(public.decode(), issuer=ISSUER, audience=AUDIENCE)
    app = create_app(Settings(**settings), verifier=verifier, databases=OrgDatabases(), audit=log)
    router = secured_router()

    @router.get("/test/store")
    def store(store: MissionStore = Depends(org_store)) -> dict[str, str]:
        return {"org": store.org_id}

    app.include_router(router)
    return app


def token(signer, org: str = "org-a") -> str:
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": "u1", "org": org, "iat": now, "exp": now + 300}
    return jwt.encode(claims, signer, algorithm="ES256")


def test_a_failed_login_is_recorded_without_the_token(signer):
    log = AuditLog()
    forged = token(ec.generate_private_key(ec.SECP256R1()))

    local_client(build_app(signer, log)).get(
        "/v1/test/store", headers={"Authorization": f"Bearer {forged}"}
    )

    assert [(e.kind, e.client) for e in log.events()] == [("auth_failed", "testclient")]
    assert forged not in str(log.events())


def test_blocking_is_recorded_when_it_starts_not_for_every_refusal(signer):
    log = AuditLog()
    client = local_client(build_app(signer, log, rate_limit_per_minute=1))

    for _ in range(5):
        client.get("/v1/health")

    assert [e.kind for e in log.events()] == ["rate_limited"]


def test_a_too_large_body_is_recorded_without_the_body(signer):
    log = AuditLog()
    body = b"SECRET-FIELD-NOTE " * 100_000

    local_client(build_app(signer, log)).post("/v1/health", content=body)

    assert [e.kind for e in log.events()] == ["body_too_large"]
    assert "SECRET-FIELD-NOTE" not in str(log.events())


def test_an_organization_without_a_database_is_recorded(signer):
    log = AuditLog()

    local_client(build_app(signer, log)).get(
        "/v1/test/store", headers={"Authorization": f"Bearer {token(signer, 'org-x')}"}
    )

    event = log.events()[-1]
    assert (event.kind, event.org_id, event.actor) == ("org_without_database", "org-x", "u1")


def test_a_new_blocking_spell_is_recorded_again(signer):
    class Clock:
        now = 1000.0

        def __call__(self) -> float:
            return self.now

    clock, log = Clock(), AuditLog()
    app = create_app(Settings(rate_limit_per_minute=1), audit=log, clock=clock)
    client = local_client(app)

    for _ in range(3):
        client.get("/v1/health")  # allowed, then blocked twice: one record
    clock.now += 60
    for _ in range(2):
        client.get("/v1/health")  # allowed again, then blocked: a second record

    assert [e.kind for e in log.events()] == ["rate_limited", "rate_limited"]


def test_a_chunked_large_body_is_recorded(signer):
    log = AuditLog()
    app = build_app(signer, log, max_body_bytes=1000)

    @app.post("/v1/test/upload")
    async def upload(request: Request) -> dict[str, int]:
        return {"bytes": len(await request.body())}

    def chunks():
        for _ in range(5):
            yield b"x" * 300

    local_client(app).post("/v1/test/upload", content=chunks())

    assert [e.kind for e in log.events()] == ["body_too_large"]
