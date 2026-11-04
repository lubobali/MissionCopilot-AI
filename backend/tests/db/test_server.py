"""Building the real server (#88): database addresses come from the environment or secret files, and
the server refuses to start unless every database is reachable, fully migrated and named the way the
directory says (fail closed). Each organization gets its own connection pool."""

import logging
import os
import time
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.migrations import load, migrate
from missioncopilot_backend.db.missions import ORG_MIGRATIONS
from missioncopilot_backend.db.organizations import OrgDatabase, drop_organization, provision
from missioncopilot_backend.pack_format import key_id
from missioncopilot_backend.server import StartupError, build
from missioncopilot_backend.signing_key import load_signing_key, new_signing_key
from tests.db.postgres import admin_url, throwaway_database
from tests.unit.clients import local_client

pytestmark = pytest.mark.db


@dataclass
class World:
    directory_url: str
    secrets: Path
    org: OrgDatabase
    signing_key: Path

    def env(self, **extra: str) -> dict[str, str]:
        return {
            "MISSIONCOPILOT_ENV": "test",
            "MISSIONCOPILOT_DIRECTORY_URL": self.directory_url,
            "MISSIONCOPILOT_ORG_URLS_DIR": str(self.secrets),
            "MISSIONCOPILOT_SIGNING_KEY_FILE": str(self.signing_key),
        } | extra


def _secret(path: Path, text: str, mode: int = 0o600) -> Path:
    path.write_text(text + "\n")
    os.chmod(path, mode)
    return path


def _app_url(org: OrgDatabase, **override: str) -> str:
    fields = {"user": org.app_role, "password": org.app_password, "dbname": org.database}
    return make_conninfo(admin_url(), **(fields | override))


@contextmanager
def _world(tmp_path: Path) -> Generator[World]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    secrets = tmp_path / "org-urls"
    secrets.mkdir(mode=0o700)
    with throwaway_database() as directory_url:
        with Directory.open(directory_url) as directory:
            org = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
            directory.add_organization(org_id, org.database)
        try:
            _secret(secrets / f"{org_id}.url", _app_url(org))
            key = tmp_path / "keys" / "signing-key.pem"
            new_signing_key(key)
            yield World(directory_url, secrets, org, key)
        finally:
            drop_organization(admin_url(), org_id)


@pytest.fixture
def world(tmp_path) -> Generator[World]:
    with _world(tmp_path) as found:
        yield found


def _refused(env: dict[str, str], match: str) -> None:
    with pytest.raises(StartupError, match=match):
        build(env)


def test_the_server_starts_with_every_database_in_place(world):
    with local_client(build(world.env())) as client:
        answer = client.get("/v1/health").json()
        assert answer["status"] == "ok"
        assert abs(answer["time"] - time.time()) < 5  # the real server's clock, in Unix seconds


def test_the_real_server_is_ready_only_while_its_directory_answers(world):
    name = sql.Identifier(str(conninfo_to_dict(world.directory_url)["dbname"]))
    with (
        local_client(build(world.env())) as client,
        psycopg.connect(admin_url(), autocommit=True) as admin,
    ):
        assert client.get("/v1/ready").status_code == 200
        admin.execute(sql.SQL("ALTER DATABASE {} ALLOW_CONNECTIONS false").format(name))
        admin.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity"
            " WHERE datname = %s AND pid <> pg_backend_pid()",
            [conninfo_to_dict(world.directory_url)["dbname"]],
        )
        try:
            down = client.get("/v1/ready")
            assert (down.status_code, down.headers["retry-after"]) == (503, "5")
            assert client.get("/v1/health").status_code == 200  # alive, just not ready
        finally:
            admin.execute(sql.SQL("ALTER DATABASE {} ALLOW_CONNECTIONS true").format(name))


def test_the_start_is_logged_once_with_the_key_id_and_no_secret(world, caplog):
    caplog.set_level(logging.INFO, logger="uvicorn.error")

    build(world.env())

    lines = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert len(lines) == 1
    public = load_signing_key(world.signing_key).public_key()
    assert f"signing_key={key_id(public)}" in lines[0]
    assert world.org.app_password not in lines[0]
    assert "password" not in lines[0]


def test_each_organization_gets_its_own_pool_into_its_own_database(world):
    app = build(world.env())
    with local_client(app):
        store = app.state.databases.for_org(world.org.org_id)
        assert store is not None and store.org_id == world.org.org_id
        assert app.state.databases.for_org("org-unknown") is None


def test_security_events_land_in_the_directory_database(world):
    with local_client(build(world.env())) as client:
        assert client.get("/v1/devices").status_code == 401

    with psycopg.connect(world.directory_url) as conn:
        kinds = conn.execute("SELECT kind FROM audit_events").fetchall()
    assert kinds == [("auth_failed",)]


def test_the_pools_are_closed_when_the_server_stops(world):
    app = build(world.env())
    with local_client(app):
        pool = app.state.databases.pools[world.org.org_id]

    assert pool.closed


def test_without_a_directory_the_server_does_not_start(world):
    env = world.env()
    del env["MISSIONCOPILOT_DIRECTORY_URL"]

    _refused(env, "MISSIONCOPILOT_DIRECTORY_URL")


def test_the_directory_address_can_come_from_a_secret_file(world, tmp_path):
    env = world.env()
    del env["MISSIONCOPILOT_DIRECTORY_URL"]
    env["MISSIONCOPILOT_DIRECTORY_URL_FILE"] = str(
        _secret(tmp_path / "directory.url", world.directory_url)
    )

    with local_client(build(env)) as client:
        assert client.get("/v1/health").status_code == 200


def test_a_secret_given_twice_is_refused(world, tmp_path):
    file = _secret(tmp_path / "directory.url", world.directory_url)

    _refused(world.env(MISSIONCOPILOT_DIRECTORY_URL_FILE=str(file)), "both")


def test_without_the_organizations_folder_the_server_does_not_start(world):
    env = world.env()
    del env["MISSIONCOPILOT_ORG_URLS_DIR"]

    _refused(env, "MISSIONCOPILOT_ORG_URLS_DIR")


def test_a_secret_file_others_can_read_is_refused(world):
    os.chmod(world.secrets / f"{world.org.org_id}.url", 0o640)

    _refused(world.env(), "readable by others")


def test_an_organization_without_its_secret_file_is_refused(world):
    (world.secrets / f"{world.org.org_id}.url").unlink()

    _refused(world.env(), f"no database address for {world.org.org_id}")


def test_a_secret_file_for_an_unknown_organization_is_refused(world):
    _secret(world.secrets / "org-stranger.url", _app_url(world.org))

    _refused(world.env(), "org-stranger is not in the directory")


def test_an_address_into_another_database_is_refused(world):
    _secret(world.secrets / f"{world.org.org_id}.url", _app_url(world.org, dbname="postgres"))

    _refused(world.env(), "points at postgres")


def test_a_wrong_password_is_refused_at_start(world):
    _secret(world.secrets / f"{world.org.org_id}.url", _app_url(world.org, password="wrong"))  # noqa: S106

    _refused(world.env(), "cannot connect")


def test_an_organization_database_behind_the_code_is_refused(world):
    with psycopg.connect(make_conninfo(admin_url(), dbname=world.org.database)) as admin:
        admin.execute("DELETE FROM schema_migrations WHERE version = 1")  # as if never migrated

    _refused(world.env(), "run the migrations first")


def test_a_directory_behind_the_code_is_refused(world):
    with psycopg.connect(world.directory_url) as conn:
        conn.execute("DELETE FROM schema_migrations WHERE version = 2")

    _refused(world.env(), "run the migrations first")


def test_starting_never_runs_migrations_itself(world):
    with psycopg.connect(world.directory_url) as conn:
        conn.execute("DELETE FROM schema_migrations WHERE version = 2")

    with pytest.raises(StartupError):
        build(world.env())

    with psycopg.connect(world.directory_url) as conn:
        assert conn.execute("SELECT max(version) FROM schema_migrations").fetchone() == (1,)


def test_migrating_again_after_the_check_brings_it_back(world):
    # The fix the error message names works: the operator migrates, the server starts.
    with psycopg.connect(world.directory_url) as conn:
        conn.execute("DROP TABLE audit_events CASCADE")
        conn.execute("DROP FUNCTION audit_events_append_only")
        conn.execute("DELETE FROM schema_migrations WHERE version = 2")
    migrate(world.directory_url, load(Directory.MIGRATIONS))

    with local_client(build(world.env())) as client:
        assert client.get("/v1/health").status_code == 200


def test_the_server_signs_with_the_key_in_its_file(world):
    app = build(world.env())

    assert app.state.signing_key.public_key() == load_signing_key(world.signing_key).public_key()


def test_without_a_signing_key_the_server_does_not_start(world):
    env = world.env()
    del env["MISSIONCOPILOT_SIGNING_KEY_FILE"]

    _refused(env, "MISSIONCOPILOT_SIGNING_KEY_FILE")


def test_a_private_key_in_an_environment_variable_is_refused(world):
    _refused(world.env(MISSIONCOPILOT_SIGNING_KEY="a key pasted here"), "as a file")


def test_a_signing_key_others_can_read_is_refused(world):
    os.chmod(world.signing_key, 0o644)

    _refused(world.env(), "readable by others")
