"""Enrolling a phone (threat model T26). The phone sends its Secure Enclave public key, a one-time
code and a signature proving it holds the private key; it becomes a pending device of the code's
organization and person. Every failure gets the same 401, and a failed proof does not burn the
code. Proof of possession does not stop a stolen code (a thief makes their own key): manager
approval does."""

import base64

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.devices import (
    CODE_LIFETIME_SECONDS,
    DeviceRegistry,
    EnrollmentCodes,
    enrollment_message,
)
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

URL = "/v1/devices/enroll"


class Clock:
    now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def der(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def enrollment(code: str, key, signed_by=None, signed_code: str | None = None) -> dict[str, str]:
    """What the phone sends; signed_by and signed_code let a test forge the proof."""
    message = enrollment_message(signed_code or code, der(key))
    proof = (signed_by or key).sign(message, ec.ECDSA(hashes.SHA256()))
    return {"code": code, "publicKeyDER": b64(der(key)), "proof": b64(proof)}


@pytest.fixture
def world():
    clock, log = Clock(), AuditLog()
    codes, devices = EnrollmentCodes(clock=clock), DeviceRegistry(clock=clock)
    app = create_app(Settings(), enrollment_codes=codes, devices=devices, audit=log)
    return local_client(app), codes, devices, clock, log


def new_key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def test_a_phone_enrolls_as_pending_for_the_codes_person(world):
    client, codes, devices, _, _ = world
    code, _ = codes.issue("org-b", "officer-7", "Officer 7 iPhone")
    key = new_key()

    response = client.post(URL, json=enrollment(code, key))

    assert response.status_code == 201
    body = response.json()
    assert (body["userId"], body["label"], body["status"]) == (
        "officer-7",
        "Officer 7 iPhone",
        "pending",
    )
    device = devices.find(body["id"])
    assert device is not None and device.org_id == "org-b" and device.public_key_der == der(key)


def failures(codes, clock) -> dict[str, dict[str, str]]:
    key, other = new_key(), new_key()
    p384 = ec.generate_private_key(ec.SECP384R1())
    used, _ = codes.issue("org-a", "u", "p")
    codes.consume(used)
    expired, _ = codes.issue("org-a", "u", "p")
    clock.now += CODE_LIFETIME_SECONDS
    live, _ = codes.issue("org-a", "u", "p")
    return {
        "unknown code": enrollment("no-such-code", key),
        "used code": enrollment(used, key),
        "expired code": enrollment(expired, key),
        "proof by another key": enrollment(live, key, signed_by=other),
        "proof for another code": enrollment(live, key, signed_code="other-code"),
        "not a P-256 key": enrollment(live, p384),
        "garbage key": {"code": live, "publicKeyDER": b64(b"junk"), "proof": b64(b"junk")},
        "not base64": {"code": live, "publicKeyDER": "%%%", "proof": "%%%"},
    }


def test_every_failure_gets_the_same_401(world):
    client, codes, _, clock, _ = world
    answers = {}
    for name, body in failures(codes, clock).items():
        response = client.post(URL, json=body)
        assert response.status_code == 401, name
        answers[name] = response.json()

    assert len({str(answer) for answer in answers.values()}) == 1


def test_a_failed_proof_does_not_burn_the_code(world):
    client, codes, _, _, _ = world
    code, _ = codes.issue("org-a", "officer-7", "phone")
    key = new_key()

    client.post(URL, json=enrollment(code, key, signed_by=new_key()))

    assert client.post(URL, json=enrollment(code, key)).status_code == 201


def test_a_key_enrolls_only_once(world):
    client, codes, _, _, _ = world
    key = new_key()
    first, _ = codes.issue("org-a", "officer-7", "phone")
    second, _ = codes.issue("org-b", "officer-9", "phone")

    assert client.post(URL, json=enrollment(first, key)).status_code == 201
    assert client.post(URL, json=enrollment(second, key)).status_code == 401


def test_the_request_is_strict(world):
    client, codes, _, _, _ = world
    code, _ = codes.issue("org-a", "officer-7", "phone")

    body = enrollment(code, new_key()) | {"status": "active"}

    assert client.post(URL, json=body).status_code == 422


def test_enrollment_is_recorded_without_the_code(world):
    client, codes, _, _, log = world
    code, _ = codes.issue("org-a", "officer-7", "phone")
    client.post(URL, json={"code": code, "publicKeyDER": "%%%", "proof": "%%%"})
    client.post(URL, json=enrollment(code, new_key()))

    assert [(e.kind, e.org_id, e.actor) for e in log.events()] == [
        ("enrollment_failed", None, None),
        ("device_enrolled", "org-a", "officer-7"),
    ]
    assert code not in str(log.events())
