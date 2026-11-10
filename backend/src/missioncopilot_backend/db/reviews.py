"""A manager's decision on a report (#178, steps 8.8.0-8.8.1), in the organization's own database:
endorsed (with the passkey assertion behind it) or sent back with a note. One final decision per
version, append-only; Postgres refuses a decision by anyone on the mission's own team (separation of
duties, sql/organization/0006_reviews.sql)."""

import hashlib
from dataclasses import dataclass
from typing import Literal

import psycopg
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.session import as_manager

Decision = Literal["endorsed", "sent_back"]
COLUMNS = "version, decision, note, reviewer_id, reviewer_name, reviewed_at, approval_hash"


@dataclass(frozen=True)
class Assertion:
    """The passkey's answer to the endorse challenge, kept as it came."""

    credential_id: bytes
    authenticator_data: bytes
    client_data: bytes
    signature: bytes


@dataclass(frozen=True)
class Review:
    version: int
    decision: Decision
    note: str | None
    reviewer_id: str
    reviewer_name: str
    reviewed_at: float
    approval_hash: str


class Decided(Exception):
    """This version already has its decision."""


class NotAllowed(Exception):
    """The manager is on the mission's team (separation of duties)."""


def approval_hash(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def read_reviews(conn: psycopg.Connection, mission_id: str) -> list[Review]:
    rows = conn.execute(
        f"SELECT {COLUMNS} FROM report_reviews WHERE mission_id = %s ORDER BY version",  # noqa: S608
        [mission_id],
    ).fetchall()
    return [Review(*row) for row in rows]


class Reviews:
    def __init__(self, pool: ConnectionPool):
        self._pool = pool

    def on_team(self, manager_id: str, mission_id: str) -> bool:
        with as_manager(self._pool, manager_id) as conn:
            row = conn.execute(
                "SELECT 1 FROM mission_members WHERE mission_id = %s AND user_id = %s",
                [mission_id, manager_id],
            ).fetchone()
        return row is not None

    def of(self, mission_id: str, manager_id: str) -> list[Review]:
        with as_manager(self._pool, manager_id) as conn:
            return read_reviews(conn, mission_id)

    def decide(
        self,
        manager_id: str,
        name: str,
        mission_id: str,
        version: int,
        decision: Decision,
        note: str | None,
        hashed: str,
        at: float,
        assertion: Assertion | None = None,
    ) -> Review:
        if decision == "endorsed" and assertion is None:
            raise ValueError("an endorsement needs the passkey's assertion")
        if decision == "sent_back" and not (note and note.strip()):
            raise ValueError("sending back needs a note")
        touch = assertion or Assertion(b"", b"", b"", b"")
        parts = [touch.credential_id, touch.authenticator_data, touch.client_data, touch.signature]
        try:
            with as_manager(self._pool, manager_id) as conn:
                conn.execute(
                    "INSERT INTO report_reviews VALUES (%s, %s, %s, %s, %s, %s, %s, %s,"
                    " %s, %s, %s, %s)",
                    [mission_id, version, decision, note.strip() if note else None, manager_id,
                     name, at, hashed, *(parts if assertion else [None] * 4)],
                )  # fmt: skip
        except psycopg.errors.UniqueViolation:
            raise Decided from None
        except psycopg.errors.InsufficientPrivilege:
            raise NotAllowed from None
        return Review(version, decision, note.strip() if note else None, manager_id, name, at,
                      hashed)  # fmt: skip
