"""Row-level security inside an organization's database (ADR 0008 server rule 2, #88): an officer
sees only the missions they belong to. The rule lives in Postgres, forced even on the table owner,
so a query the server gets wrong still cannot return another team's mission."""

import uuid
from collections.abc import Generator
from contextlib import contextmanager

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS, PostgresMissions, as_user
from missioncopilot_backend.db.organizations import OrgDatabase, drop_organization, provision
from missioncopilot_backend.tenancy import Mission
from tests.db.postgres import admin_url

pytestmark = pytest.mark.db

SEED = """
INSERT INTO missions (id, title) VALUES
    ('kandor-roads', 'Kandor Rural Roads, Package 1'), ('kandor-bridges', 'Kandor Bridges');
INSERT INTO mission_members (mission_id, user_id) VALUES
    ('kandor-roads', 'officer-7'), ('kandor-bridges', 'officer-8'), ('kandor-roads', 'officer-8');
"""


@contextmanager
def _org() -> Generator[tuple[OrgDatabase, ConnectionPool]]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    org = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    try:
        with psycopg.connect(_url(org, admin=True), autocommit=True) as admin:
            admin.execute(SEED)
        with ConnectionPool(_url(org), min_size=1, max_size=2, open=True) as pool:
            yield org, pool
    finally:
        drop_organization(admin_url(), org_id)


def _url(org: OrgDatabase, admin: bool = False) -> str:
    if admin:
        return make_conninfo(admin_url(), dbname=org.database)
    return make_conninfo(
        admin_url(), user=org.app_role, password=org.app_password, dbname=org.database
    )


@pytest.fixture
def org():
    with _org() as found:
        yield found


def test_a_member_sees_their_mission(org):
    _, pool = org

    mission = PostgresMissions(pool, "acme").get("officer-7", "kandor-roads")

    assert mission == Mission("kandor-roads", "acme", "Kandor Rural Roads, Package 1")


def test_another_teams_mission_looks_exactly_like_a_missing_one(org):
    _, pool = org
    missions = PostgresMissions(pool, "acme")

    assert missions.get("officer-7", "kandor-bridges") is None
    assert missions.get("officer-7", "no-such-mission") is None


def test_the_list_holds_only_the_officers_own_missions(org):
    _, pool = org
    missions = PostgresMissions(pool, "acme")

    assert [m.id for m in missions.for_user("officer-7")] == ["kandor-roads"]
    assert [m.id for m in missions.for_user("officer-8")] == ["kandor-bridges", "kandor-roads"]


@pytest.mark.parametrize("user_id", ["", "nobody"])
def test_an_unknown_or_empty_user_sees_nothing(org, user_id):
    _, pool = org

    assert PostgresMissions(pool, "acme").for_user(user_id) == []


def test_with_no_user_set_the_database_shows_nothing(org):
    org_db, _ = org
    with psycopg.connect(_url(org_db)) as conn:
        assert conn.execute("SELECT count(*) FROM missions").fetchone() == (0,)


def test_the_user_does_not_carry_over_to_the_next_request_on_a_pooled_connection(org):
    org_db, _ = org
    with ConnectionPool(_url(org_db), min_size=1, max_size=1, open=True) as pool:
        with as_user(pool, "officer-7") as conn:
            first = conn.info.backend_pid
            assert conn.execute("SELECT count(*) FROM missions").fetchone() == (1,)

        with pool.connection() as conn:
            assert conn.info.backend_pid == first  # truly the same connection, back from the pool
            assert conn.execute("SELECT count(*) FROM missions").fetchone() == (0,)


def test_an_officer_only_sees_their_own_memberships(org):
    _, pool = org
    with as_user(pool, "officer-7") as conn:
        rows = conn.execute("SELECT mission_id, user_id FROM mission_members").fetchall()

    assert rows == [("kandor-roads", "officer-7")]


def test_the_app_login_cannot_switch_row_security_off(org):
    org_db, _ = org
    with psycopg.connect(_url(org_db), autocommit=True) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("ALTER TABLE missions DISABLE ROW LEVEL SECURITY")
        conn.execute("SET row_security = off")
        with pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"):
            conn.execute("SELECT * FROM missions")


def test_row_security_binds_even_the_table_owner(org):
    org_db, _ = org
    with psycopg.connect(_url(org_db, admin=True)) as conn:
        conn.execute(sql.SQL("SET ROLE {}").format(sql.Identifier(org_db.owner_role)))
        assert conn.execute("SELECT count(*) FROM missions").fetchone() == (0,)


def test_the_app_login_cannot_add_or_join_missions(org):
    _, pool = org
    for insert in (
        "INSERT INTO missions (id, title) VALUES ('mine', 'Mine')",
        "INSERT INTO mission_members VALUES ('kandor-bridges', 'officer-7')",
    ):
        with (
            pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"),
            as_user(pool, "officer-7") as conn,
        ):
            conn.execute(insert)


def test_the_app_login_cannot_touch_the_migration_records(org):
    org_db, _ = org
    with psycopg.connect(_url(org_db), autocommit=True) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("DELETE FROM schema_migrations")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT * FROM schema_migrations")


def test_every_table_the_app_can_reach_has_forced_row_security(org):
    org_db, _ = org
    with psycopg.connect(_url(org_db, admin=True)) as conn:
        rows = conn.execute(
            "SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity FROM pg_class c"
            " JOIN pg_namespace n ON n.oid = c.relnamespace"
            " WHERE n.nspname = 'public' AND c.relkind = 'r'"
            " AND has_table_privilege(%s, c.oid, 'SELECT')",
            [org_db.app_role],
        ).fetchall()

    assert rows, "the app should reach some tables"
    assert [name for name, enabled, forced in rows if not (enabled and forced)] == []


def test_no_team_member_can_have_an_empty_user_id(org):
    # After a transaction the setting reads '' (not NULL), so an empty member would match everyone
    # with no user set. The table refuses one, even from an admin.
    org_db, _ = org
    with (
        psycopg.connect(_url(org_db, admin=True)) as conn,
        pytest.raises(psycopg.errors.CheckViolation),
    ):
        conn.execute("INSERT INTO mission_members VALUES ('kandor-roads', '')")
