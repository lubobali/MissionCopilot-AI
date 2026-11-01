"""Enrollment codes (threat model T26): only an admin issues one; it enrolls one named person's
phone in the admin's organization, works once, expires after 15 minutes, and is stored only as a
hash, so a copy of the store does not reveal a live code."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.auth import TokenVerifier
from missioncopilot_backend.devices import CODE_LIFETIME_SECONDS, EnrollmentCodes
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

ISSUER, AUDIENCE = "https://login.example.org", "missioncopilot-api"
URL = "/v1/devices/enrollment-codes"
BODY = {"userId": "officer-7", "deviceLabel": "Officer 7 iPhone"}


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def as_role(signer, *roles: str, org: str = "org-a") -> dict[str, str]:
    now = int(time.time())
    claims: dict[str, object] = {"iss": ISSUER, "aud": AUDIENCE, "sub": "admin-1", "org": org}
    claims["roles"] = list(roles)
    claims |= {"iat": now, "exp": now + 300}
    return {"Authorization": f"Bearer {jwt.encode(claims, signer, algorithm='ES256')}"}


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def codes(clock) -> EnrollmentCodes:
    return EnrollmentCodes(clock=clock)


@pytest.fixture
def log() -> AuditLog:
    return AuditLog()


@pytest.fixture
def client(signer, codes, log):
    public = signer.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    verifier = TokenVerifier(public.decode(), issuer=ISSUER, audience=AUDIENCE)
    return local_client(
        create_app(Settings(), verifier=verifier, enrollment_codes=codes, audit=log)
    )


def test_an_admin_issues_a_code_for_15_minutes(client, signer):
    response = client.post(URL, json=BODY, headers=as_role(signer, "admin"))

    assert response.status_code == 201
    assert len(response.json()["code"]) >= 22  # 128 random bits
    assert response.json()["expiresAt"] == "2027-01-15T08:15:00Z"


@pytest.mark.parametrize("roles", [["manager"], ["officer"], []])
def test_only_an_admin_may_issue_codes(client, signer, roles):
    assert client.post(URL, json=BODY, headers=as_role(signer, *roles)).status_code == 403


def test_no_token_cannot_issue_codes(client):
    assert client.post(URL, json=BODY).status_code == 401


def test_a_code_is_bound_to_the_admins_organization_person_and_label(client, signer, codes):
    code = client.post(URL, json=BODY, headers=as_role(signer, "admin", org="org-b")).json()["code"]

    grant = codes.consume(code)

    assert grant is not None
    assert (grant.org_id, grant.user_id, grant.device_label) == (
        "org-b",
        "officer-7",
        BODY["deviceLabel"],
    )


def test_a_code_works_once(codes):
    code, _ = codes.issue("org-a", "officer-7", "phone")

    assert codes.consume(code) is not None
    assert codes.consume(code) is None


def test_a_code_expires_after_15_minutes(codes, clock):
    code, _ = codes.issue("org-a", "officer-7", "phone")
    clock.now += CODE_LIFETIME_SECONDS

    assert codes.consume(code) is None


def test_a_code_just_before_expiry_still_works(codes, clock):
    code, _ = codes.issue("org-a", "officer-7", "phone")
    clock.now += CODE_LIFETIME_SECONDS - 1

    assert codes.consume(code) is not None


def test_an_unknown_code_gets_nothing(codes):
    assert codes.consume("not-a-real-code") is None


def test_only_the_hash_of_a_code_is_stored(codes):
    code, _ = codes.issue("org-a", "officer-7", "phone")

    assert code not in repr(vars(codes))


def test_codes_do_not_repeat(codes):
    assert len({codes.issue("org-a", "u", "p")[0] for _ in range(1000)}) == 1000


@pytest.mark.parametrize(
    "body",
    [BODY | {"org": "org-b"}, BODY | {"deviceLabel": "x" * 81}, {"userId": "officer-7"}],
)
def test_the_request_is_strict(client, signer, body):
    assert client.post(URL, json=body, headers=as_role(signer, "admin")).status_code == 422


def test_issuing_is_recorded_without_the_code(client, signer, log):
    code = client.post(URL, json=BODY, headers=as_role(signer, "admin")).json()["code"]

    issued = [e for e in log.events() if e.kind == "enrollment_code_issued"]
    assert [(e.org_id, e.actor) for e in issued] == [("org-a", "admin-1")]
    assert code not in str(log.events())
