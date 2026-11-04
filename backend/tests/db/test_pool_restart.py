"""After Postgres restarts, the first request still works (#103 step 4.4, S4). A pool keeps idle
connections; a restart kills them, and without a check the next request is handed a dead one and
fails with a 500. Every pool now checks a connection before handing it out and replaces a broken
one. The restart is played by killing the pool's server connections, as a restart does."""

from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict

from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.pools import open_pool
from tests.db.postgres import admin_url, throwaway_database

pytestmark = pytest.mark.db

SRC = Path(__file__).resolve().parents[2] / "src" / "missioncopilot_backend"


def _kill_connections(url: str) -> int:
    """What a Postgres restart does to the pool's idle connections."""
    database = conninfo_to_dict(url)["dbname"]
    with psycopg.connect(admin_url(), autocommit=True) as admin:
        killed = admin.execute(
            "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity"
            " WHERE datname = %s AND pid <> pg_backend_pid()",
            [database],
        ).fetchone()
    return killed[0] if killed else 0


def test_a_pool_hands_out_a_working_connection_after_a_restart():
    with throwaway_database() as url, open_pool(url) as pool:
        with pool.connection() as conn:
            conn.execute("SELECT 1")

        assert _kill_connections(url) >= 1  # the pool's idle connection is now dead

        with pool.connection() as conn:
            assert conn.execute("SELECT 41 + 1").fetchone() == (42,)


def test_the_directory_works_after_a_restart():
    with throwaway_database() as url, Directory.open(url) as directory:
        directory.devices.find("no-such-phone")
        _kill_connections(url)

        assert directory.devices.find("no-such-phone") is None  # an answer, not an error


def test_every_pool_in_the_server_comes_from_the_checked_factory():
    makers = [
        path.relative_to(SRC).as_posix()
        for path in SRC.rglob("*.py")
        if "ConnectionPool(" in path.read_text(encoding="utf-8")
    ]

    assert makers == ["db/pools.py"]
