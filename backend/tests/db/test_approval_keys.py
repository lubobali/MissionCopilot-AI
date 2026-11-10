"""Approval keys (#171): the same contract on the in-memory stand-in and on the directory database,
and the database refuses to change or remove a kept key."""

import uuid
from collections.abc import Iterator

import psycopg
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.approval_keys import ApprovalKeys, ApprovalKeyStore, KeyTaken, key_id
from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.devices import DeviceRegistry, DeviceStore, EnrollmentGrant
from tests.db.postgres import throwaway_database

pytestmark = pytest.mark.db


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


def der() -> bytes:
    return (
        ec.generate_private_key(ec.SECP256R1())
        .public_key()
        .public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    )


@pytest.fixture(params=["memory", "postgres"])
def stores(request) -> Iterator[tuple[ApprovalKeyStore, DeviceStore, Clock, str | None]]:
    clock = Clock()
    if request.param == "memory":
        yield ApprovalKeys(clock=clock), DeviceRegistry(clock=clock), clock, None
        return
    with throwaway_database() as url, Directory.open(url, clock=clock) as directory:
        directory.add_organization("org-a", database="mc_org_a")
        yield directory.approval_keys, directory.devices, clock, url


def phone(devices: DeviceStore) -> str:
    device = devices.add(EnrollmentGrant("org-a", "officer-7", "phone", 0.0), der())
    assert device is not None
    return device.id


def test_a_key_is_kept_oldest_first(stores):
    keys, devices, clock, _ = stores
    device = phone(devices)
    # the newer key sorts first by id, so only the time can give this order
    second, first = sorted((der(), der()), key=key_id)

    added = keys.add(device, first)
    clock.now += 10
    keys.add(device, second)

    assert added.key_id == key_id(first) and added.added_at == 1_800_000_000.0
    assert [k.public_key_der for k in keys.keys_of(device)] == [first, second]
    assert keys.find(device, key_id(first)) == added
    assert keys.find(device, key_id(der())) is None
    assert keys.find(str(uuid.uuid4()), key_id(first)) is None, "only that phone's key"


def test_the_same_key_twice_is_one_record(stores):
    keys, devices, clock, _ = stores
    device, key = phone(devices), der()
    first = keys.add(device, key)
    clock.now += 10

    assert keys.add(device, key) == first
    assert len(keys.keys_of(device)) == 1


def test_one_key_belongs_to_one_phone(stores):
    keys, devices, _, _ = stores
    key = der()
    keys.add(phone(devices), key)

    with pytest.raises(KeyTaken):
        keys.add(phone(devices), key)


def test_the_database_never_changes_or_removes_a_key(stores):
    keys, devices, _, url = stores
    if url is None:
        pytest.skip("the database's own rule")
    keys.add(phone(devices), der())

    statements = (
        "UPDATE device_approval_keys SET added_at = 0",
        "DELETE FROM device_approval_keys",
    )
    for statement in statements:
        with psycopg.connect(url) as conn, pytest.raises(psycopg.errors.RaiseException):
            conn.execute(statement)
