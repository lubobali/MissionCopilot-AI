"""The directory database (#88): enrollment codes and devices behave exactly like the in-memory
stand-ins the unit tests use (one contract, run on both), and the races memory cannot have are
closed by Postgres itself."""

import threading
from collections.abc import Generator, Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import psycopg
import pytest

from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.devices import (
    CODE_LIFETIME_SECONDS,
    CodeStore,
    DeviceRegistry,
    DeviceStore,
    EnrollmentCodes,
    EnrollmentGrant,
)
from tests.db.postgres import throwaway_database

pytestmark = pytest.mark.db


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


@dataclass
class Stores:
    codes: CodeStore
    devices: DeviceStore
    clock: Clock
    url: str | None = None


@contextmanager
def _postgres_stores() -> Generator[Stores]:
    clock = Clock()
    with throwaway_database() as url, Directory.open(url, clock=clock) as directory:
        for org in ("org-a", "org-b"):
            directory.add_organization(org, database=f"mc_{org.replace('-', '_')}")
        yield Stores(directory.codes, directory.devices, clock, url)


@pytest.fixture(params=["memory", "postgres"])
def stores(request) -> Iterator[Stores]:
    """The same contract, run on the in-memory stand-in and on the directory database."""
    if request.param == "memory":
        clock = Clock()
        yield Stores(EnrollmentCodes(clock=clock), DeviceRegistry(clock=clock), clock)
        return
    with _postgres_stores() as found:
        yield found


@pytest.fixture
def postgres() -> Iterator[Stores]:
    with _postgres_stores() as found:
        yield found


def _grant(org="org-a", user="officer-7") -> EnrollmentGrant:
    return EnrollmentGrant(org, user, f"{user} iPhone", expires_at=0)


# Enrollment codes


def test_a_code_works_once(stores):
    code, _ = stores.codes.issue("org-a", "officer-7", "phone")

    assert stores.codes.consume(code) == EnrollmentGrant(
        "org-a", "officer-7", "phone", stores.clock.now + CODE_LIFETIME_SECONDS
    )
    assert stores.codes.consume(code) is None


def test_a_code_expires_after_15_minutes(stores):
    code, _ = stores.codes.issue("org-a", "officer-7", "phone")
    stores.clock.now += CODE_LIFETIME_SECONDS

    assert stores.codes.consume(code) is None


def test_a_code_just_before_expiry_still_works(stores):
    code, _ = stores.codes.issue("org-a", "officer-7", "phone")
    stores.clock.now += CODE_LIFETIME_SECONDS - 1

    assert stores.codes.consume(code) is not None


def test_an_unknown_code_gets_nothing(stores):
    assert stores.codes.consume("not-a-real-code") is None


def test_codes_do_not_repeat(stores):
    assert len({stores.codes.issue("org-a", "u", "p")[0] for _ in range(200)}) == 200


# Devices


def test_an_added_device_is_pending_and_found_by_id(stores):
    device = stores.devices.add(_grant(), b"key-1")

    assert device is not None
    assert (device.org_id, device.user_id, device.status) == ("org-a", "officer-7", "pending")
    assert (device.enrolled_at, device.last_seq) == (stores.clock.now, 0)
    assert stores.devices.find(device.id) == device


def test_an_unknown_device_is_not_found(stores):
    assert stores.devices.find("6f1c1f2e-0000-4000-8000-000000000000") is None


@pytest.mark.parametrize("device_id", ["not-a-uuid", "", "1' OR '1'='1"])
def test_a_malformed_device_id_from_a_request_is_just_not_found(stores, device_id):
    assert stores.devices.find(device_id) is None
    assert stores.devices.in_org("org-a", device_id) is None


def test_a_key_enrolls_only_once(stores):
    stores.devices.add(_grant(), b"key-1")

    assert stores.devices.has_key(b"key-1")
    assert not stores.devices.has_key(b"key-2")
    assert stores.devices.add(_grant(user="officer-8"), b"key-1") is None


def test_another_organizations_device_looks_missing(stores):
    device = stores.devices.add(_grant("org-a"), b"key-1")
    assert device is not None

    assert stores.devices.in_org("org-a", device.id) == device
    assert stores.devices.in_org("org-b", device.id) is None


def test_an_organizations_list_has_its_own_devices_pending_first(stores):
    first = stores.devices.add(_grant(user="u1"), b"k1")
    stores.clock.now += 1
    second = stores.devices.add(_grant(user="u2"), b"k2")
    stores.clock.now += 1
    stores.devices.add(_grant("org-b", user="u3"), b"k3")
    assert first is not None and second is not None
    stores.devices.update(first, status="active")

    assert [d.user_id for d in stores.devices.of_org("org-a")] == ["u2", "u1"]


def test_an_update_is_kept(stores):
    device = stores.devices.add(_grant(), b"key-1")
    assert device is not None

    revoked = stores.devices.update(device, status="revoked")

    assert revoked.status == "revoked"
    assert stores.devices.find(device.id) == revoked


def test_a_request_number_must_always_go_up(stores):
    device = stores.devices.add(_grant(), b"key-1")
    assert device is not None

    assert stores.devices.accept_seq(device.id, 5)
    assert not stores.devices.accept_seq(device.id, 5)  # a replay
    assert not stores.devices.accept_seq(device.id, 4)  # an older one
    assert stores.devices.accept_seq(device.id, 6)
    found = stores.devices.find(device.id)
    assert found is not None and found.last_seq == 6


def test_the_clock_is_the_stores_own(stores):
    assert stores.devices.now() == stores.clock.now


# Only Postgres: what a copy of the database shows, and races between two requests


def test_a_copy_of_the_database_holds_no_live_code(postgres):
    code, _ = postgres.codes.issue("org-a", "officer-7", "phone")

    with psycopg.connect(str(postgres.url)) as conn:
        dump = str(conn.execute("SELECT * FROM enrollment_codes").fetchall())

    assert code not in dump


def test_two_phones_racing_with_one_code_only_one_wins(postgres):
    code, _ = postgres.codes.issue("org-a", "officer-7", "phone")
    results: list[object] = []
    racers = [
        threading.Thread(target=lambda: results.append(postgres.codes.consume(code)))
        for _ in range(8)
    ]
    for racer in racers:
        racer.start()
    for racer in racers:
        racer.join()

    assert sum(r is not None for r in results) == 1


def test_racing_requests_with_the_same_number_only_one_is_accepted(postgres):
    device = postgres.devices.add(_grant(), b"key-1")
    assert device is not None
    results: list[bool] = []
    racers = [
        threading.Thread(target=lambda: results.append(postgres.devices.accept_seq(device.id, 7)))
        for _ in range(8)
    ]
    for racer in racers:
        racer.start()
    for racer in racers:
        racer.join()

    assert results.count(True) == 1


def test_a_device_must_belong_to_a_known_organization(postgres):
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        postgres.devices.add(_grant("org-unknown"), b"key-9")


def test_only_status_label_and_request_number_can_change(postgres):
    device = postgres.devices.add(_grant(), b"key-1")
    assert device is not None

    with pytest.raises(ValueError, match="org_id"):
        postgres.devices.update(device, org_id="org-b")  # never move a phone between organizations


def test_updating_a_device_that_is_gone_is_an_error(postgres):
    device = postgres.devices.add(_grant(), b"key-1")
    assert device is not None
    with psycopg.connect(str(postgres.url)) as conn:
        conn.execute("DELETE FROM devices")

    with pytest.raises(LookupError):
        postgres.devices.update(device, status="active")
