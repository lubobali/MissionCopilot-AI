"""The officer's Face ID approval key reaches the server (#171, step 8.1.1). The phone sends its
approval key's public key in a signed request; the server keeps it with that phone, append-only, so
a later sync can check an approval (#172, threat T13 on the server side). A key the server never saw
cannot approve."""

import base64
import json

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.app import create_app
from missioncopilot_backend.approval_keys import ApprovalKeys, key_id
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client
from tests.unit.test_device_requests import Clock, Phone

pytestmark = pytest.mark.unit

PATH = "/v1/devices/me/approval-key"


def der(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


@pytest.fixture
def world():
    clock, log = Clock(), AuditLog()
    devices, keys = DeviceRegistry(clock=clock), ApprovalKeys(clock=clock)
    app = create_app(Settings(), devices=devices, audit=log, approval_keys=keys)
    return local_client(app), devices, keys, clock, log


def send(client, phone: Phone, clock: Clock, public_key_der: bytes):
    body = json.dumps({"publicKeyDER": base64.b64encode(public_key_der).decode()}).encode()
    headers = phone.headers(PATH, body, clock.now) | {"Content-Type": "application/json"}
    return client.post(PATH, content=body, headers=headers)


def test_a_new_key_is_kept_with_the_phone(world):
    client, devices, keys, clock, log = world
    phone, approval = Phone(devices), der(ec.generate_private_key(ec.SECP256R1()))

    response = send(client, phone, clock, approval)

    assert response.status_code == 201
    assert response.json() == {"keyId": key_id(approval), "addedAt": "2027-01-15T08:00:00Z"}
    assert [k.public_key_der for k in keys.keys_of(phone.id)] == [approval]
    added = [e for e in log.events() if e.kind == "approval_key_added"]
    expected = [("org-a", "officer-7", key_id(approval))]
    assert [(e.org_id, e.actor, e.subject) for e in added] == expected


def test_the_same_key_again_is_the_same_record(world):
    client, devices, keys, clock, _ = world
    phone, approval = Phone(devices), der(ec.generate_private_key(ec.SECP256R1()))
    first = send(client, phone, clock, approval)
    clock.now += 60

    again = send(client, phone, clock, approval)

    assert again.status_code == 200 and again.json() == first.json()
    assert len(keys.keys_of(phone.id)) == 1


def test_a_second_key_is_added_and_the_first_kept(world):
    client, devices, keys, clock, _ = world
    phone = Phone(devices)
    old, new = (der(ec.generate_private_key(ec.SECP256R1())) for _ in range(2))
    send(client, phone, clock, old)
    clock.now += 60

    assert send(client, phone, clock, new).status_code == 201
    assert [k.public_key_der for k in keys.keys_of(phone.id)] == [old, new], "oldest first"
    assert keys.find(phone.id, key_id(old)) is not None, "old approvals still check"


def test_another_phones_key_is_refused(world):
    client, devices, _, clock, _ = world
    approval = der(ec.generate_private_key(ec.SECP256R1()))
    send(client, Phone(devices), clock, approval)

    assert send(client, Phone(devices), clock, approval).status_code == 409


@pytest.mark.parametrize(
    "bad",
    [b"not a key", der(ec.generate_private_key(ec.SECP384R1()))],
    ids=["garbage", "p384"],
)
def test_only_a_p256_public_key(world, bad):
    client, devices, keys, clock, _ = world
    phone = Phone(devices)

    assert send(client, phone, clock, bad).status_code == 422
    assert keys.keys_of(phone.id) == []


def test_the_phones_own_request_key_is_refused(world):
    client, devices, keys, clock, _ = world
    phone = Phone(devices)

    assert send(client, phone, clock, der(phone.key)).status_code == 422, "one key, one job"
    assert keys.keys_of(phone.id) == []


def test_not_base64_is_refused(world):
    client, devices, _, clock, _ = world
    phone = Phone(devices)
    body = b'{"publicKeyDER": "%%%"}'
    headers = phone.headers(PATH, body, clock.now) | {"Content-Type": "application/json"}

    assert client.post(PATH, content=body, headers=headers).status_code == 422


@pytest.mark.parametrize("status", ["pending", "revoked"])
def test_a_pending_or_revoked_phone_cannot_add_a_key(world, status):
    client, devices, keys, clock, _ = world
    phone = Phone(devices, status=status)

    assert send(client, phone, clock, der(ec.generate_private_key(ec.SECP256R1()))).status_code in (
        401,
        410,
    )
    assert keys.keys_of(phone.id) == []
