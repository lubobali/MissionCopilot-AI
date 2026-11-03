"""The audit log in the directory database (threat T38, #88). Same chain and same checks as the
in-memory log (audit.py); Postgres refuses any change or removal (sql/directory/0002_audit.sql), and
a transaction lock makes two writers take turns, so the chain never forks."""

import time
from collections.abc import Callable

from psycopg_pool import ConnectionPool

from missioncopilot_backend.audit import GENESIS, AuditEvent, Kind, verify_chain

LOCK = 0x4D43_4155  # pg_advisory_xact_lock key ("MCAU"): one audit writer at a time


class PostgresAuditLog:
    def __init__(self, pool: ConnectionPool, clock: Callable[[], float] = time.time):
        self._pool, self._clock = pool, clock

    def record(
        self,
        kind: Kind,
        *,
        client: str | None = None,
        org_id: str | None = None,
        actor: str | None = None,
        subject: str | None = None,
    ) -> AuditEvent:
        with self._pool.connection() as conn, conn.transaction():
            conn.execute("SELECT pg_advisory_xact_lock(%s)", [LOCK])
            last = conn.execute(
                "SELECT seq, hash FROM audit_events ORDER BY seq DESC LIMIT 1"
            ).fetchone()
            seq, prev = (last[0] + 1, last[1]) if last else (0, GENESIS)
            event = AuditEvent(seq, self._clock(), kind, client, org_id, actor, subject, prev)
            event = event.replace(hash=event.content_hash())
            conn.execute(
                "INSERT INTO audit_events (seq, at, kind, client, org_id, actor, subject,"
                " prev_hash, hash) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                [seq, event.at, kind, client, org_id, actor, subject, prev, event.hash],
            )
        return event

    def events(self) -> tuple[AuditEvent, ...]:
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT seq, at, kind, client, org_id, actor, subject, prev_hash, hash"
                " FROM audit_events ORDER BY seq"
            ).fetchall()
        return tuple(AuditEvent(*row) for row in rows)

    def head(self) -> str:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT hash FROM audit_events ORDER BY seq DESC LIMIT 1").fetchone()
        return row[0] if row else GENESIS

    def verify(self) -> list[str]:
        return verify_chain(self.events())
