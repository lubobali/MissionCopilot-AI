"""Audit log of security events (threat model T38). Append-only: there is no way to change or remove
an entry, and each entry carries the hash of the one before, so verify() finds an entry changed or
removed in the store underneath. It records who, what, when and from where; never tokens or request
bodies. Removing the newest entries is only caught against a copy of head() kept elsewhere, the same
limit as the phone's evidence chain. In memory for now; Phase 8 moves it to an insert-only table."""

import dataclasses
import hashlib
import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal

GENESIS = "0" * 64
Kind = Literal[
    "auth_failed", "role_denied", "rate_limited", "body_too_large", "org_without_database"
]


@dataclass(frozen=True)
class AuditEvent:
    seq: int
    at: float
    kind: Kind
    client: str | None
    org_id: str | None
    actor: str | None
    prev_hash: str
    hash: str = ""

    def content_hash(self) -> str:
        fields = dataclasses.asdict(self)
        del fields["hash"]
        return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()

    def replace(self, **changes: object) -> "AuditEvent":
        return dataclasses.replace(self, **changes)


class AuditLog:
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
    ) -> AuditEvent:
        event = AuditEvent(
            len(self._events), self._clock(), kind, client, org_id, actor, self.head()
        )
        event = event.replace(hash=event.content_hash())
        self._events.append(event)
        return event

    def events(self) -> tuple[AuditEvent, ...]:
        return tuple(self._events)

    def head(self) -> str:
        return self._events[-1].hash if self._events else GENESIS

    def verify(self) -> list[str]:
        problems, prev = [], GENESIS
        for index, event in enumerate(self._events):
            if event.prev_hash != prev:
                before = f"entry {index - 1}" if index else "the start"
                problems.append(f"entry {index} does not follow {before}")
            elif event.content_hash() != event.hash:
                problems.append(f"entry {index} was changed")
            prev = event.hash
        return problems
