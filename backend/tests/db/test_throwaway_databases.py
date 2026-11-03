"""Each database test gets a fresh, empty Postgres database that is dropped afterwards (#88)."""

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict

from tests.db.postgres import admin_url, throwaway_database

pytestmark = pytest.mark.db


def _names() -> set[str]:
    with psycopg.connect(admin_url(), autocommit=True) as admin:
        return {row[0] for row in admin.execute("SELECT datname FROM pg_database")}


def test_the_server_is_postgres_18():
    with psycopg.connect(admin_url()) as admin:
        row = admin.execute("SHOW server_version_num").fetchone()

    assert row is not None and 180000 <= int(row[0]) < 190000


def test_a_throwaway_database_exists_only_while_in_use():
    with throwaway_database() as url:
        name = conninfo_to_dict(url)["dbname"]
        assert name in _names()
        with psycopg.connect(url) as conn:
            assert conn.execute("SELECT current_database()").fetchone() == (name,)

    assert name not in _names()


def test_a_throwaway_database_is_dropped_even_when_still_connected():
    with throwaway_database() as url:
        name = conninfo_to_dict(url)["dbname"]
        left_open = psycopg.connect(url)  # a test that forgets to close must not leak a database

    assert name not in _names()
    left_open.close()


def test_two_throwaway_databases_never_share_a_name():
    with throwaway_database() as first, throwaway_database() as second:
        assert first != second


def test_without_a_server_address_the_tests_fail_and_say_how_to_start_one(monkeypatch, tmp_path):
    monkeypatch.delenv("MISSIONCOPILOT_TEST_ADMIN_URL", raising=False)

    with pytest.raises(RuntimeError, match="docker compose"):
        admin_url(env_file=tmp_path / "missing.env")


def test_a_throwaway_database_is_dropped_when_the_test_fails():
    with pytest.raises(ZeroDivisionError), throwaway_database() as url:
        name = conninfo_to_dict(url)["dbname"]
        _ = 1 / 0

    assert name not in _names()


def test_the_ci_address_wins_over_the_local_file(monkeypatch, tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("MISSIONCOPILOT_TEST_ADMIN_URL=postgresql://from-file/postgres\n")
    monkeypatch.setenv("MISSIONCOPILOT_TEST_ADMIN_URL", "postgresql://from-ci/postgres")

    assert admin_url(env_file=env_file) == "postgresql://from-ci/postgres"


def test_the_local_file_is_used_when_ci_sets_nothing(monkeypatch, tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("MISSIONCOPILOT_TEST_ADMIN_URL=postgresql://from-file/postgres\n")
    monkeypatch.delenv("MISSIONCOPILOT_TEST_ADMIN_URL", raising=False)

    assert admin_url(env_file=env_file) == "postgresql://from-file/postgres"
