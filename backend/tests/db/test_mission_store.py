"""One contract for reading missions as a user (#88), run on the in-memory stand-in the route tests
use and on an organization's real database, where Postgres row-level security does the team check.
They cannot drift apart."""

import uuid
from collections.abc import Generator

import psycopg
import pytest
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS, PostgresMissions
from missioncopilot_backend.db.organizations import drop_organization, provision
from missioncopilot_backend.tenancy import Mission, MissionReader, MissionStore
from tests.db.postgres import admin_url

pytestmark = pytest.mark.db

ROADS = Mission("kandor-roads", "acme", "Kandor Rural Roads, Package 1")
BRIDGES = Mission("kandor-bridges", "acme", "Kandor Bridges")
TEAMS = {ROADS: ("officer-7", "officer-8"), BRIDGES: ("officer-8",)}


def _postgres() -> Generator[MissionReader]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    org = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    try:
        with psycopg.connect(make_conninfo(admin_url(), dbname=org.database)) as admin:
            for mission, team in TEAMS.items():
                admin.execute(
                    "INSERT INTO missions (id, title) VALUES (%s, %s)", [mission.id, mission.title]
                )
                for user in team:
                    admin.execute("INSERT INTO mission_members VALUES (%s, %s)", [mission.id, user])
        url = make_conninfo(
            admin_url(), user=org.app_role, password=org.app_password, dbname=org.database
        )
        with ConnectionPool(url, min_size=1, max_size=2, open=True) as pool:
            yield PostgresMissions(pool, "acme")
    finally:
        drop_organization(admin_url(), org_id)


@pytest.fixture(params=["memory", "postgres"])
def missions(request) -> Generator[MissionReader]:
    if request.param == "memory":
        store = MissionStore("acme")
        for mission, team in TEAMS.items():
            store.add(mission, team)
        yield store
        return
    yield from _postgres()


def test_a_team_member_reads_the_mission(missions):
    assert missions.get("officer-7", "kandor-roads") == ROADS


def test_another_teams_and_a_missing_mission_both_give_nothing(missions):
    assert missions.get("officer-7", "kandor-bridges") is None
    assert missions.get("officer-7", "no-such-mission") is None


def test_the_list_holds_the_users_missions_in_id_order(missions):
    assert missions.for_user("officer-8") == [BRIDGES, ROADS]
    assert missions.for_user("officer-7") == [ROADS]


@pytest.mark.parametrize("user_id", ["", "nobody"])
def test_an_empty_or_unknown_user_gets_nothing(missions, user_id):
    assert missions.get(user_id, "kandor-roads") is None
    assert missions.for_user(user_id) == []


def test_the_store_knows_its_organization(missions):
    assert missions.org_id == "acme"


def test_a_team_member_without_a_user_id_is_refused_in_memory_too():
    with pytest.raises(ValueError, match="user id"):
        MissionStore("acme").add(ROADS, team=("",))
