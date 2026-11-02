"""Shred order on next contact (ADR 0012, threat model T18). When the organization revokes a phone,
its next genuinely signed request gets a server-signed order to destroy every mission it holds. The
order goes only to the real phone: a forged, unknown or pending caller still gets the same 401, so
nobody learns that a phone was revoked. Without a server key the old 401 stays (fail closed)."""

import base64

import jsonschema
import pytest
import yaml
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.shred_order import SCOPE, SHRED_PROBLEM, shred_message
from tests.unit.clients import local_client
from tests.unit.test_device_requests import Clock, Phone
from tests.unit.test_openapi_contract import SPEC_PATH

pytestmark = pytest.mark.unit

PATH, BODY = "/v1/test/missions/m1/sync", b"{}"
SERVER_KEY = ec.generate_private_key(ec.SECP256R1())


def build_app(devices: DeviceRegistry, log: AuditLog, key=SERVER_KEY) -> FastAPI:
    app = create_app(Settings(), devices=devices, audit=log, shred_key=key)
    router = device_router()

    @router.post("/test/missions/{mission_id}/sync")
    def sync(mission_id: str, device: DevicePrincipal = Depends(require_device)) -> dict:
        return {"mission": mission_id}

    app.include_router(router)
    return app


@pytest.fixture
def world():
    clock, log = Clock(), AuditLog()
    devices = DeviceRegistry(clock=clock)
    return build_app(devices, log), devices, clock, log


def send(app, phone, clock, **kwargs):
    headers = phone.headers(PATH, BODY, clock.now, **kwargs)
    return local_client(app).post(PATH, content=BODY, headers=headers)


def revoked(devices) -> Phone:
    phone = Phone(devices)
    devices.update(devices.find(phone.id), status="revoked")
    return phone


def verifies(order: dict, signature: str) -> bool:
    message = shred_message(order["deviceId"], order["issuedAt"])
    try:
        SERVER_KEY.public_key().verify(
            base64.b64decode(signature), message, ec.ECDSA(hashes.SHA256())
        )
    except InvalidSignature:
        return False
    return True


def test_a_revoked_phone_gets_a_signed_order_to_shred_every_mission(world):
    app, devices, clock, _ = world
    phone = revoked(devices)

    response = send(app, phone, clock)

    assert response.status_code == 410
    assert response.headers["content-type"] == "application/problem+json"
    body = response.json()
    assert body["type"] == SHRED_PROBLEM
    assert body["order"] == {"deviceId": phone.id, "scope": SCOPE, "issuedAt": int(clock.now)}
    assert verifies(body["order"], body["signature"])


def test_the_signature_covers_the_device_so_the_order_cannot_be_replayed_to_another_phone(world):
    app, devices, clock, _ = world
    body = send(app, revoked(devices), clock).json()

    assert not verifies(body["order"] | {"deviceId": "another-phone"}, body["signature"])
    assert not verifies(
        body["order"] | {"issuedAt": body["order"]["issuedAt"] + 1}, body["signature"]
    )


def test_a_forged_request_for_a_revoked_phone_learns_nothing(world):
    app, devices, clock, _ = world
    phone = revoked(devices)
    stranger = ec.generate_private_key(ec.SECP256R1())

    response = send(app, phone, clock, key=stranger)

    assert response.status_code == 401
    assert "order" not in response.json()


def test_an_old_request_from_a_revoked_phone_gets_no_order(world):
    app, devices, clock, _ = world
    phone = revoked(devices)
    headers = phone.headers(PATH, BODY, clock.now - 3600)  # signed an hour ago

    response = local_client(app).post(PATH, content=BODY, headers=headers)

    assert response.status_code == 401


def test_pending_and_unknown_phones_get_the_same_401_as_before(world):
    app, devices, clock, _ = world
    pending = Phone(devices, status="pending")
    unknown = Phone(DeviceRegistry(clock=clock))

    answers = [send(app, phone, clock) for phone in (pending, unknown)]

    assert [a.status_code for a in answers] == [401, 401]
    assert answers[0].json() == answers[1].json()


def test_without_a_server_key_a_revoked_phone_still_gets_401(world):
    _, devices, clock, log = world
    app = build_app(devices, log, key=None)

    assert send(app, revoked(devices), clock).status_code == 401


def test_the_answer_matches_the_contract(world):
    app, devices, clock, _ = world
    schema = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))["components"]["schemas"]

    jsonschema.validate(send(app, revoked(devices), clock).json(), schema["ShredOrder"])


def test_the_order_is_recorded(world):
    app, devices, clock, log = world
    phone = revoked(devices)

    send(app, phone, clock)

    assert [(e.kind, e.subject) for e in log.events()] == [("shred_order_sent", phone.id)]


def test_an_active_phone_is_unaffected(world):
    app, devices, clock, _ = world

    assert send(app, Phone(devices), clock).json() == {"mission": "m1"}


def test_the_signed_order_bytes_are_fixed():
    # The phone checks exactly these bytes (Phase 8); changing them breaks every phone.
    assert shred_message("dev-1", 1_800_000_000) == (
        b"missioncopilot-shred-v1\ndev-1\nall-missions\n1800000000"
    )
