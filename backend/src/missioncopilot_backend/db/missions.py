"""Missions in an organization's own database, read as one user (#88). Postgres row-level security
decides what that user may see (sql/organization/0001_missions.sql); this code only says who is
asking, for one transaction at a time, so a pooled connection never carries a user over."""

from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import psycopg
from psycopg_pool import ConnectionPool

from missioncopilot_backend.tenancy import Mission

ORG_MIGRATIONS = Path(__file__).parent / "sql" / "organization"


@contextmanager
def as_user(pool: ConnectionPool, user_id: str) -> Generator[psycopg.Connection]:
    """A connection inside one transaction in which Postgres knows the caller. The setting is local
    to the transaction: it ends with it, whatever happens."""
    with pool.connection() as conn, conn.transaction():
        conn.execute("SELECT set_config('app.user_id', %s, true)", [user_id])
        yield conn


class PostgresMissions:
    def __init__(self, pool: ConnectionPool, org_id: str):
        self._pool, self.org_id = pool, org_id

    def get(self, user_id: str, mission_id: str) -> Mission | None:
        """The mission if this user is on its team; another team's mission and a missing one both
        give None."""
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT id, title FROM missions WHERE id = %s", [mission_id]
            ).fetchone()
        return Mission(row[0], self.org_id, row[1]) if row else None

    def for_user(self, user_id: str) -> list[Mission]:
        with as_user(self._pool, user_id) as conn:
            rows = conn.execute("SELECT id, title FROM missions ORDER BY id").fetchall()
        return [Mission(mission_id, self.org_id, title) for mission_id, title in rows]
