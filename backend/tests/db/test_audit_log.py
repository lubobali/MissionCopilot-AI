"""The audit log on disk (threat T38, #88): the same chain as the in-memory log (one contract, run
on both), kept in the directory database, refused any change or removal by the database itself, and
never forked by two requests writing at once."""

import threading
from collections.abc import Generator

import psycopg
import pytest

from missioncopilot_backend.audit import GENESIS, AuditLog, AuditStore
from missioncopilot_backend.db.directory import Directory
from tests.db.postgres import throwaway_database

pytestmark = pytest.mark.db


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.25

    def __call__(self) -> float:
        self.now += 1
        return self.now


@pytest.fixture(params=["memory", "postgres"])
def log(request) -> Generator[AuditStore]:
    if request.param == "memory":
        yield AuditLog(clock=Clock())
        return
    with throwaway_database() as url, Directory.open(url, clock=Clock()) as directory:
        yield directory.audit


@pytest.fixture
def postgres() -> Generator[tuple[str, AuditStore]]:
    with throwaway_database() as url, Directory.open(url, clock=Clock()) as directory:
        yield url, directory.audit


def test_an_empty_log_starts_at_the_genesis_hash(log):
    assert log.events() == ()
    assert log.head() == GENESIS
    assert log.verify() == []


def test_each_entry_is_chained_to_the_one_before(log):
    first = log.record("auth_failed", client="10.0.0.1")
    second = log.record("device_enrolled", org_id="org-a", actor="officer-7", subject="dev-1")

    assert (first.seq, second.seq) == (0, 1)
    assert first.prev_hash == GENESIS and second.prev_hash == first.hash
    assert second.hash == second.content_hash()
    assert log.head() == second.hash
    assert log.events() == (first, second)
    assert log.verify() == []


def test_what_was_recorded_comes_back_exactly(log):
    event = log.record("role_denied", client="10.0.0.2", org_id="org-b", actor="admin-1")

    (stored,) = log.events()

    assert stored == event
    assert (stored.kind, stored.client, stored.org_id, stored.actor, stored.subject) == (
        "role_denied",
        "10.0.0.2",
        "org-b",
        "admin-1",
        None,
    )


# Only Postgres: what the database itself refuses, and two writers at once


@pytest.mark.parametrize(
    "statement",
    [
        "UPDATE audit_events SET actor = 'someone-else'",
        "DELETE FROM audit_events",
        "TRUNCATE audit_events",
    ],
)
def test_the_database_refuses_to_change_or_remove_entries_even_for_an_admin(postgres, statement):
    url, log = postgres
    log.record("auth_failed")

    with (
        psycopg.connect(url) as conn,
        pytest.raises(psycopg.errors.RaiseException, match="append-only"),
    ):
        conn.execute(statement)


def test_an_entry_changed_behind_the_databases_back_is_found(postgres):
    url, log = postgres
    log.record("auth_failed")
    log.record("device_revoked", org_id="org-a", subject="dev-1")
    with psycopg.connect(url) as conn:  # an attacker with full control switches the guard off
        conn.execute("ALTER TABLE audit_events DISABLE TRIGGER USER")
        conn.execute("UPDATE audit_events SET subject = 'dev-2' WHERE seq = 1")

    assert log.verify() == ["entry 1 was changed"]


def test_an_entry_removed_behind_the_databases_back_is_found(postgres):
    url, log = postgres
    for _ in range(3):
        log.record("auth_failed")
    with psycopg.connect(url) as conn:
        conn.execute("ALTER TABLE audit_events DISABLE TRIGGER USER")
        conn.execute("DELETE FROM audit_events WHERE seq = 1")

    assert log.verify() == ["entry 2 does not follow entry 0"]


def test_two_requests_writing_at_once_never_fork_the_chain(postgres):
    _, log = postgres
    writers = [threading.Thread(target=log.record, args=("rate_limited",)) for _ in range(8)]
    for writer in writers:
        writer.start()
    for writer in writers:
        writer.join()

    assert [e.seq for e in log.events()] == list(range(8))
    assert log.verify() == []
