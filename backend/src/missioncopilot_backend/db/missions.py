"""Missions in an organization's own database, read as one user (#88). Postgres row-level security
decides what that user may see (sql/organization/0001_missions.sql); this code only says who is
asking, for one transaction at a time, so a pooled connection never carries a user over."""

from pathlib import Path

from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.packs import PostgresPacks
from missioncopilot_backend.db.session import as_user
from missioncopilot_backend.tenancy import Mission

ORG_MIGRATIONS = Path(__file__).parent / "sql" / "organization"


class PostgresOrgDatabases:
    """One pool per organization, each logged in as that organization's own app login into its own
    database. An organization with no pool gets nothing."""

    def __init__(self, pools: dict[str, ConnectionPool]):
        self.pools = pools

    def for_org(self, org_id: str) -> "PostgresMissions | None":
        pool = self.pools.get(org_id)
        return PostgresMissions(pool, org_id) if pool else None

    def packs_for(self, org_id: str) -> PostgresPacks | None:
        pool = self.pools.get(org_id)
        return PostgresPacks(pool) if pool else None


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
