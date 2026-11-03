"""The migration runner on a real Postgres (#88): pending files run in order, each in its own
transaction with its record; an edited or unknown migration stops everything."""

import threading

import psycopg
import pytest

from missioncopilot_backend.db.migrations import MigrationError, load, migrate, pending
from tests.db.postgres import throwaway_database

pytestmark = pytest.mark.db


def _files(folder, **files):
    for name, body in files.items():
        (folder / name).write_text(body, encoding="utf-8")
    return load(folder)


def _tables(url) -> set[str]:
    with psycopg.connect(url) as conn:
        rows = conn.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        ).fetchall()
    return {row[0] for row in rows}


def _recorded(url) -> list[tuple[int, str]]:
    with psycopg.connect(url) as conn:
        return conn.execute(
            "SELECT version, name FROM schema_migrations ORDER BY version"
        ).fetchall()


def test_pending_migrations_run_in_order_and_are_recorded(tmp_path):
    migrations = _files(
        tmp_path,
        **{
            "0001_people.sql": "CREATE TABLE people (id int PRIMARY KEY);",
            "0002_pets.sql": "CREATE TABLE pets (owner int REFERENCES people (id));",
        },
    )
    with throwaway_database() as url:
        assert migrate(url, migrations) == [1, 2]

        assert {"people", "pets"} <= _tables(url)
        assert _recorded(url) == [(1, "0001_people.sql"), (2, "0002_pets.sql")]


def test_running_again_applies_nothing(tmp_path):
    migrations = _files(tmp_path, **{"0001_people.sql": "CREATE TABLE people (id int);"})
    with throwaway_database() as url:
        migrate(url, migrations)

        assert migrate(url, migrations) == []


def test_only_the_new_migration_runs_later(tmp_path):
    first = _files(tmp_path, **{"0001_people.sql": "CREATE TABLE people (id int);"})
    with throwaway_database() as url:
        migrate(url, first)
        both = _files(tmp_path, **{"0002_pets.sql": "CREATE TABLE pets (id int);"})

        assert migrate(url, both) == [2]


def test_a_failing_migration_leaves_no_trace(tmp_path):
    migrations = _files(
        tmp_path,
        **{
            "0001_people.sql": "CREATE TABLE people (id int);",
            "0002_broken.sql": "CREATE TABLE half (id int); SELECT * FROM missing_table;",
        },
    )
    with throwaway_database() as url:
        with pytest.raises(psycopg.errors.UndefinedTable):
            migrate(url, migrations)

        assert "half" not in _tables(url)  # the whole file rolled back
        assert _recorded(url) == [(1, "0001_people.sql")]  # the good one before it stays


def test_a_migration_edited_after_it_ran_stops_everything(tmp_path):
    original = _files(tmp_path, **{"0001_people.sql": "CREATE TABLE people (id int);"})
    with throwaway_database() as url:
        migrate(url, original)
        edited = _files(
            tmp_path,
            **{
                "0001_people.sql": "CREATE TABLE people (id bigint);",
                "0002_pets.sql": "CREATE TABLE pets (id int);",
            },
        )

        with pytest.raises(MigrationError, match="0001_people.sql was edited after it ran"):
            migrate(url, edited)
        assert "pets" not in _tables(url)


def test_a_database_newer_than_the_code_is_refused(tmp_path):
    newer, older = tmp_path / "newer", tmp_path / "older"
    newer.mkdir()
    older.mkdir()
    with throwaway_database() as url:
        migrate(url, _files(newer, **{"0001_a.sql": "SELECT 1;", "0002_b.sql": "SELECT 2;"}))

        with pytest.raises(MigrationError, match="0002_b.sql"):
            migrate(url, _files(older, **{"0001_a.sql": "SELECT 1;"}))


def test_two_servers_starting_at_once_apply_each_migration_once(tmp_path):
    migrations = _files(
        tmp_path,
        **{
            "0001_slow.sql": "SELECT pg_sleep(0.5); CREATE TABLE people (id int);",
            "0002_pets.sql": "CREATE TABLE pets (id int);",
        },
    )
    with throwaway_database() as url:
        results: list[list[int]] = []
        errors: list[BaseException] = []

        def start():
            try:
                results.append(migrate(url, migrations))
            except BaseException as error:  # noqa: BLE001 - reported below
                errors.append(error)

        servers = [threading.Thread(target=start) for _ in range(2)]
        for server in servers:
            server.start()
        for server in servers:
            server.join()

        assert errors == []
        assert sorted(results) == [[], [1, 2]]
        assert _recorded(url) == [(1, "0001_slow.sql"), (2, "0002_pets.sql")]


def test_a_migration_and_its_record_commit_together(tmp_path):
    # The file itself succeeds, but saving its record fails: then the file's work must go too, or
    # the next start would run it a second time.
    refuse_records = """
        CREATE TABLE half (id int);
        CREATE FUNCTION refuse() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN RAISE EXCEPTION 'no record'; END $$;
        CREATE TRIGGER refuse BEFORE INSERT ON schema_migrations
            FOR EACH ROW EXECUTE FUNCTION refuse();
    """
    migrations = _files(tmp_path, **{"0001_refuse_records.sql": refuse_records})
    with throwaway_database() as url:
        with pytest.raises(psycopg.errors.RaiseException):
            migrate(url, migrations)

        assert "half" not in _tables(url)
        assert _recorded(url) == []


def test_pending_on_a_fresh_database_is_everything_and_changes_nothing(tmp_path):
    migrations = _files(tmp_path, **{"0001_a.sql": "SELECT 1;", "0002_b.sql": "SELECT 2;"})
    with throwaway_database() as url:
        assert pending(url, migrations) == [1, 2]

        assert "schema_migrations" not in _tables(url)  # only looked


def test_pending_after_migrating_is_nothing_and_new_files_show_up(tmp_path):
    first = _files(tmp_path, **{"0001_a.sql": "SELECT 1;"})
    with throwaway_database() as url:
        migrate(url, first)
        assert pending(url, first) == []

        assert pending(url, _files(tmp_path, **{"0002_b.sql": "SELECT 2;"})) == [2]


def test_pending_refuses_an_edited_migration(tmp_path):
    with throwaway_database() as url:
        migrate(url, _files(tmp_path, **{"0001_a.sql": "SELECT 1;"}))

        with pytest.raises(MigrationError, match="edited"):
            pending(url, _files(tmp_path, **{"0001_a.sql": "SELECT 'changed';"}))
