"""Audit log of security events (threat model T38). Append-only: there is no way to change or remove
an entry, and each entry carries the hash of the one before, so verify() finds an entry changed or
removed in the store underneath. It records who, what, when and from where; never tokens or request
bodies. Removing the newest entries is only caught against a copy of head() kept elsewhere, the same
limit as the phone's evidence chain. The server keeps it in the directory database, where Postgres
itself refuses changes (db/audit_log.py); AuditLog here is the in-memory stand-in for tests, and
one contract test runs on both (tests/db/test_audit_log.py)."""

import dataclasses
import hashlib
import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal, Protocol

GENESIS = "0" * 64
Kind = Literal[
    "auth_failed",
    "role_denied",
    "rate_limited",
    "body_too_large",
    "org_without_database",
    "enrollment_code_issued",
    "enrollment_failed",
    "device_enrolled",
    "device_approved",
    "device_revoked",
    "device_auth_failed",
    "approval_key_added",
    "mission_synced",
    "shred_order_sent",
    "pack_downloaded",
]


@dataclass(frozen=True)
class AuditEvent:
    seq: int
    at: float
    kind: Kind
    client: str | None
    org_id: str | None
    actor: str | None
    subject: str | None  # what the event is about, for example a device id
    prev_hash: str
    hash: str = ""

    def content_hash(self) -> str:
        fields = dataclasses.asdict(self)
        del fields["hash"]
        return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()

    def replace(self, **changes: object) -> "AuditEvent":
        return dataclasses.replace(self, **changes)


def verify_chain(events: tuple[AuditEvent, ...]) -> list[str]:
    """Each problem found, naming entries by their number: a changed entry, or one that does not
    follow the entry before it (something between them was removed)."""
    problems, prev, prev_seq = [], GENESIS, None
    for event in events:
        if event.prev_hash != prev:
            before = "the start" if prev_seq is None else f"entry {prev_seq}"
            problems.append(f"entry {event.seq} does not follow {before}")
        elif event.content_hash() != event.hash:
            problems.append(f"entry {event.seq} was changed")
        prev, prev_seq = event.hash, event.seq
    return problems


class AuditStore(Protocol):
    def record(
        self,
        kind: Kind,
        *,
        client: str | None = None,
        org_id: str | None = None,
        actor: str | None = None,
        subject: str | None = None,
    ) -> AuditEvent: ...
    def events(self) -> tuple[AuditEvent, ...]: ...
    def head(self) -> str: ...
    def verify(self) -> list[str]: ...


class AuditLog:
    """In memory, for tests."""

    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._events: list[AuditEvent] = []

    def record(
        self,
        kind: Kind,
        *,
        client: str | None = None,
        org_id: str | None = None,
        actor: str | None = None,
        subject: str | None = None,
    ) -> AuditEvent:
        event = AuditEvent(
            len(self._events), self._clock(), kind, client, org_id, actor, subject, self.head()
        )
        event = event.replace(hash=event.content_hash())
        self._events.append(event)
        return event

    def events(self) -> tuple[AuditEvent, ...]:
        return tuple(self._events)

    def head(self) -> str:
        return self._events[-1].hash if self._events else GENESIS

    def verify(self) -> list[str]:
        return verify_chain(self.events())
