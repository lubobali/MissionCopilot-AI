"""One physical database per organization, each with its own owner and its own app login (ADR
0008, threat T31, #88). On a fresh Postgres every login may connect to every database, so these
tests prove the provisioning takes that away: one organization's login cannot even connect to
another's."""

import uuid
from collections.abc import Generator
from contextlib import contextmanager

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.organizations import (
    OrgDatabase,
    _password_hash,
    drop_organization,
    harden_cluster,
    names_for,
    provision,
)
from tests.db.postgres import admin_url, throwaway_database

pytestmark = pytest.mark.db


@contextmanager
def _org(migrations_folder=None) -> Generator[OrgDatabase]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    migrations = load(migrations_folder) if migrations_folder else []
    org = provision(admin_url(), org_id, migrations)
    try:
        yield org
    finally:
        drop_organization(admin_url(), org_id)


def _login(org: OrgDatabase, database: str | None = None, password: str | None = None) -> str:
    return make_conninfo(
        admin_url(),
        user=org.app_role,
        password=password or org.app_password,
        dbname=database or org.database,
    )


def test_the_app_login_connects_to_its_own_database():
    with _org() as org, psycopg.connect(_login(org)) as conn:
        row = conn.execute("SELECT current_user, current_database()").fetchone()

    assert row == (org.app_role, org.database)


def test_one_organizations_login_cannot_connect_to_another_organizations_database():
    with (
        _org() as a,
        _org() as b,
        pytest.raises(psycopg.OperationalError, match="permission denied for database"),
    ):
        psycopg.connect(_login(a, database=b.database))


def test_an_organizations_login_cannot_connect_to_any_other_database():
    with psycopg.connect(admin_url(), autocommit=True) as admin:  # as on a fresh server
        admin.execute("GRANT CONNECT ON DATABASE postgres, template1 TO PUBLIC")
    harden_cluster(admin_url())
    with _org() as org, throwaway_database() as directory_url, Directory.open(directory_url):
        directory = conninfo_to_dict(directory_url)["dbname"]
        for other in ("postgres", "template1", str(directory)):
            with pytest.raises(psycopg.OperationalError, match="permission denied for database"):
                psycopg.connect(_login(org, database=other))


def test_a_wrong_password_is_refused():
    with (
        _org() as org,
        pytest.raises(psycopg.OperationalError, match="password authentication failed"),
    ):
        psycopg.connect(_login(org, password="wrong"))  # noqa: S106 - wrong on purpose


def test_every_organization_gets_its_own_random_password():
    with _org() as a, _org() as b:
        assert a.app_password != b.app_password
        assert len(a.app_password) == 48


def test_the_app_login_has_no_power_over_the_server(tmp_path):
    with _org() as org, psycopg.connect(_login(org)) as conn:
        row = conn.execute(
            "SELECT rolsuper, rolcreatedb, rolcreaterole, rolbypassrls FROM pg_roles"
            " WHERE rolname = current_user"
        ).fetchone()

    assert row == (False, False, False, False)


def test_tables_belong_to_the_owner_and_the_app_can_use_but_not_change_them(tmp_path):
    notes = "CREATE TABLE notes (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, body text);"
    (tmp_path / "0001_notes.sql").write_text(notes)
    with _org(tmp_path) as org, psycopg.connect(_login(org), autocommit=True) as conn:
        owner = conn.execute(
            "SELECT tableowner FROM pg_tables WHERE tablename = 'notes'"
        ).fetchone()
        conn.execute("INSERT INTO notes (body) VALUES ('site visit')")  # uses the id sequence
        conn.execute("UPDATE notes SET body = 'site visit, km 42'")

        assert owner == (org.owner_role,)
        assert conn.execute("SELECT body FROM notes").fetchone() == ("site visit, km 42",)
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("DROP TABLE notes")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("CREATE TABLE sneaky (id int)")


def test_dropping_an_organization_removes_its_database_and_logins():
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    org = provision(admin_url(), org_id, [])

    drop_organization(admin_url(), org_id)

    with psycopg.connect(admin_url()) as admin:
        databases = admin.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", [org.database]
        ).fetchall()
        roles = admin.execute(
            "SELECT 1 FROM pg_roles WHERE rolname IN (%s, %s)", [org.app_role, org.owner_role]
        ).fetchall()
    assert databases == [] and roles == []


def test_a_failed_provisioning_leaves_nothing_behind(tmp_path):
    (tmp_path / "0001_broken.sql").write_text("SELECT * FROM missing_table;")
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    database, owner, app = names_for(org_id)

    with pytest.raises(psycopg.errors.UndefinedTable):
        provision(admin_url(), org_id, load(tmp_path))

    with psycopg.connect(admin_url()) as admin:
        assert (
            admin.execute("SELECT 1 FROM pg_database WHERE datname = %s", [database]).fetchall()
            == []
        )
        roles = admin.execute("SELECT 1 FROM pg_roles WHERE rolname IN (%s, %s)", [owner, app])
        assert roles.fetchall() == []


def test_the_password_is_hashed_before_it_is_sent():
    with psycopg.connect(admin_url()) as admin:
        hashed = _password_hash(admin, "mc_x_app", "secret-password-123")

    assert hashed.startswith("SCRAM-SHA-256$") and "secret-password-123" not in hashed


def test_names_come_from_the_organization_id():
    assert names_for("kandor-roads") == (
        "mc_org_kandor_roads",
        "mc_kandor_roads_owner",
        "mc_kandor_roads_app",
    )


@pytest.mark.parametrize(
    "org_id", ["a; DROP DATABASE postgres", "Kandor", "-x", "x", "a" * 41, "kandor_roads"]
)
def test_an_organization_id_that_is_not_a_short_lowercase_slug_is_refused(org_id):
    with pytest.raises(ValueError, match="organization id"):
        names_for(org_id)
