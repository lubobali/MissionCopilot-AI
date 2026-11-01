"""Signed device requests (threat model T26, T27). An approved phone signs each request over its
method, path, body hash, time and a strictly increasing sequence number. Replays, reordered or
changed requests, old or future times, and unknown, pending or revoked phones all get the same
401; the organization and person come from the enrolled device, never from the request."""

import base64
import hashlib

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI, Request

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.device_auth import (
    TIME_WINDOW_SECONDS,
    DevicePrincipal,
    device_router,
    request_message,
    require_device,
)
from missioncopilot_backend.devices import DeviceRegistry, EnrollmentGrant
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit


class Clock:
    now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


def build_app(devices: DeviceRegistry, log: AuditLog) -> FastAPI:
    app = create_app(Settings(), devices=devices, audit=log)
    router = device_router()

    @router.post("/test/missions/{mission_id}/sync")
    async def sync(
        mission_id: str, request: Request, device: DevicePrincipal = Depends(require_device)
    ) -> dict[str, str]:
        body = await request.body()  # the route can still read the body the check hashed
        return {
            "org": device.org_id,
            "user": device.user_id,
            "mission": mission_id,
            "body": body.decode(),
        }

    @router.post("/test/ping")
    def ping() -> dict[str, str]:  # asks for no device: only the router protects it
        return {"pong": "secret"}

    app.include_router(router)
    return app


class Phone:
    def __init__(self, devices: DeviceRegistry, org: str = "org-a", status: str = "active"):
        self.key = ec.generate_private_key(ec.SECP256R1())
        der = self.key.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
        )
        device = devices.add(EnrollmentGrant(org, "officer-7", "phone", 0.0), der)
        self.id = devices.update(device, status=status).id
        self.seq = 0

    def headers(self, path: str, body: bytes, at: float, seq: int | None = None, key=None) -> dict:
        if seq is None:
            self.seq += 1
            seq = self.seq
        message = request_message("POST", path, self.id, seq, int(at), body)
        signature = (key or self.key).sign(message, ec.ECDSA(hashes.SHA256()))
        return {
            "X-Device-Id": self.id,
            "X-Device-Seq": str(seq),
            "X-Device-Time": str(int(at)),
            "X-Device-Signature": base64.b64encode(signature).decode(),
        }


PATH, BODY = "/v1/test/missions/m1/sync", b'{"items": []}'


@pytest.fixture
def world():
    clock, log = Clock(), AuditLog()
    devices = DeviceRegistry(clock=clock)
    return local_client(build_app(devices, log)), devices, clock, log


def send(client, headers, path=PATH, body=BODY):
    return client.post(path, content=body, headers=headers)


def test_an_approved_phone_is_known_by_its_signature(world):
    client, devices, clock, _ = world
    phone = Phone(devices, org="org-b")

    response = send(client, phone.headers(PATH, BODY, clock.now) | {"X-Org": "org-a"})

    assert response.json() == {
        "org": "org-b",
        "user": "officer-7",
        "mission": "m1",
        "body": BODY.decode(),
    }


def test_a_replayed_request_is_refused(world):
    client, devices, clock, _ = world
    phone = Phone(devices)
    headers = phone.headers(PATH, BODY, clock.now)

    assert send(client, headers).status_code == 200
    assert send(client, headers).status_code == 401


def test_an_older_sequence_number_is_refused_but_gaps_are_fine(world):
    client, devices, clock, _ = world
    phone = Phone(devices)

    assert send(client, phone.headers(PATH, BODY, clock.now, seq=5)).status_code == 200
    assert send(client, phone.headers(PATH, BODY, clock.now, seq=3)).status_code == 401
    assert send(client, phone.headers(PATH, BODY, clock.now, seq=9)).status_code == 200


def test_a_failed_request_does_not_move_the_sequence_on(world):
    client, devices, clock, _ = world
    phone, thief = Phone(devices), ec.generate_private_key(ec.SECP256R1())

    send(client, phone.headers(PATH, BODY, clock.now, seq=1_000_000, key=thief))

    assert send(client, phone.headers(PATH, BODY, clock.now, seq=1)).status_code == 200


@pytest.mark.parametrize("skew", [-TIME_WINDOW_SECONDS - 1, TIME_WINDOW_SECONDS + 1])
def test_a_time_outside_the_window_is_refused(world, skew):
    client, devices, clock, _ = world
    phone = Phone(devices)

    assert send(client, phone.headers(PATH, BODY, clock.now + skew)).status_code == 401


@pytest.mark.parametrize("skew", [-TIME_WINDOW_SECONDS, TIME_WINDOW_SECONDS])
def test_a_time_at_the_edge_of_the_window_is_accepted(world, skew):
    client, devices, clock, _ = world
    phone = Phone(devices)

    assert send(client, phone.headers(PATH, BODY, clock.now + skew)).status_code == 200


def refusals(devices, clock) -> dict[str, tuple[dict, str, bytes]]:
    phone = Phone(devices)
    now = clock.now
    good = phone.headers(PATH, BODY, now)
    return {
        "changed body": (phone.headers(PATH, BODY, now), PATH, b'{"items": ["forged"]}'),
        "other mission": (phone.headers(PATH, BODY, now), "/v1/test/missions/m2/sync", BODY),
        "other key": (
            phone.headers(PATH, BODY, now, key=ec.generate_private_key(ec.SECP256R1())),
            PATH,
            BODY,
        ),
        "pending phone": (Phone(devices, status="pending").headers(PATH, BODY, now), PATH, BODY),
        "revoked phone": (Phone(devices, status="revoked").headers(PATH, BODY, now), PATH, BODY),
        "unknown phone": (
            good | {"X-Device-Id": "00000000-0000-4000-8000-000000000000"},
            PATH,
            BODY,
        ),
        "no signature": ({k: v for k, v in good.items() if k != "X-Device-Signature"}, PATH, BODY),
        "no sequence": ({k: v for k, v in good.items() if k != "X-Device-Seq"}, PATH, BODY),
        "sequence zero": (phone.headers(PATH, BODY, now, seq=0), PATH, BODY),
        "sequence not a number": (good | {"X-Device-Seq": "abc"}, PATH, BODY),
        "time not a number": (good | {"X-Device-Time": "soon"}, PATH, BODY),
        "signature not base64": (good | {"X-Device-Signature": "%%%"}, PATH, BODY),
    }


def test_every_refusal_is_the_same_401(world):
    client, devices, clock, _ = world
    answers = {}
    for name, (headers, path, body) in refusals(devices, clock).items():
        response = send(client, headers, path, body)
        assert response.status_code == 401, name
        answers[name] = response.json()

    assert len({str(answer) for answer in answers.values()}) == 1


def test_a_revoked_phone_is_refused_from_then_on(world):
    client, devices, clock, _ = world
    phone = Phone(devices)
    assert send(client, phone.headers(PATH, BODY, clock.now)).status_code == 200

    devices.update(devices.find(phone.id), status="revoked")

    assert send(client, phone.headers(PATH, BODY, clock.now)).status_code == 401


def test_refusals_are_recorded_without_the_signature(world):
    client, devices, clock, log = world
    phone = Phone(devices)
    headers = phone.headers(PATH, BODY, clock.now)
    send(client, headers)
    send(client, headers)  # replay

    assert [(e.kind, e.subject) for e in log.events()] == [("device_auth_failed", phone.id)]
    assert headers["X-Device-Signature"] not in str(log.events())


def test_the_signed_message_is_fixed():
    """The iPhone signs exactly these bytes; changing them breaks every enrolled phone."""
    message = request_message("POST", "/v1/missions/m1/sync", "dev-1", 7, 1_800_000_000, b"{}")

    assert message == (
        b"missioncopilot-request-v1\nPOST\n/v1/missions/m1/sync\ndev-1\n7\n1800000000\n"
        + hashlib.sha256(b"{}").hexdigest().encode()
    )


def test_an_unknown_device_id_never_reaches_the_log(world):
    client, devices, clock, log = world
    phone = Phone(devices)
    junk = "attacker-text-" + "x" * 500

    send(client, phone.headers(PATH, BODY, clock.now) | {"X-Device-Id": junk})

    assert [(e.kind, e.subject) for e in log.events()] == [("device_auth_failed", None)]
    assert "attacker-text" not in str(log.events())


def test_every_route_on_the_device_router_needs_a_signature(world):
    client, *_ = world

    assert client.post("/v1/test/ping").status_code == 401
