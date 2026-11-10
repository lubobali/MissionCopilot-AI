"""What the dashboard reads (#175, step 8.5.1): a manager sees every mission of their organization,
with the pack's project header and ratings and the synced report's status, red flags and sample
points, while a person who is not a manager still sees only their own team's missions. The role
comes from the server, never from the browser."""

from collections.abc import Iterator

import pytest

from missioncopilot_backend.db.dashboard_data import DashboardData
from missioncopilot_backend.db.sync import PostgresSync
from tests.db.dashboard_world import BRIDGES, ROADS, DashboardWorld, dashboard_world

pytestmark = pytest.mark.db


@pytest.fixture
def world() -> Iterator[DashboardWorld]:
    yield from dashboard_world()


def test_a_manager_sees_every_mission_with_its_header_status_and_flags(world):
    portfolio = DashboardData(world.pool).portfolio("manager-1")

    rows = {row.id: row for row in portfolio.rows}
    assert set(rows) == {ROADS, BRIDGES}, "every mission of the organization"
    roads = rows[ROADS]
    assert (roads.title, roads.country, roads.project_ref, roads.sector) == (
        "Kandor Rural Roads Project, Package 1", "Kandor", "KRRP-P1", "Transport: rural roads",
    )  # fmt: skip
    assert roads.status == "received" and roads.sentences == 3 and roads.red_flags == 1
    assert (roads.risk_now, roads.risk_before) == ("High", "Substantial")
    assert roads.received_at == 1_794_270_000.0 and roads.approved_at == 1_794_268_800.0
    assert roads.points == [(41.859881, -87.713197, 6.8)]
    bridges = rows[BRIDGES]
    assert bridges.status == "in_field" and bridges.title == "Bridges" and bridges.points == []
    assert (portfolio.to_review, portfolio.red_flags, portfolio.endorsed) == (1, 1, 0)


def test_rows_waiting_for_review_come_first(world):
    rows = DashboardData(world.pool).portfolio("manager-1").rows

    assert [row.id for row in rows] == [ROADS, BRIDGES]


def test_a_team_member_still_sees_only_their_own_mission(world):
    assert PostgresSync(world.pool).report("officer-8", ROADS) is None
    assert PostgresSync(world.pool).report("officer-7", ROADS) is not None


def test_a_manager_reads_but_never_writes(world):
    import psycopg

    from missioncopilot_backend.db.session import as_manager

    with pytest.raises(psycopg.errors.InsufficientPrivilege), as_manager(world.pool, "m") as conn:
        conn.execute("INSERT INTO reports (mission_id) VALUES (%s)", [BRIDGES])
