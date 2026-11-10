"""The project page's data (#176, step 8.6.1): from the pack the server signed and the report the
phone signed, read as a manager. The six ratings keep their own scale: performance gets better or
worse, risk goes up or down. A mission that is not the organization's is none."""

from collections.abc import Iterator

import pytest

from missioncopilot_backend.db.dashboard_data import DashboardData
from tests.db.dashboard_world import BRIDGES, ROADS, DashboardWorld, dashboard_world

pytestmark = pytest.mark.db


@pytest.fixture
def world() -> Iterator[DashboardWorld]:
    yield from dashboard_world()


def test_the_project_header_financing_and_components(world):
    view = DashboardData(world.pool).project("manager-1", ROADS)

    assert view is not None
    assert view.row.title == "Kandor Rural Roads Project, Package 1"
    assert view.facts["Implementing agency"] == "Kandor Ministry of Public Works"
    assert view.facts["Approved"] == "12 Sep 2024" and view.facts["Closing"] == "30 Jun 2027"
    assert view.objective.startswith("Improve all-season road access")
    money = view.financing
    assert money is not None and (money.total, money.disbursed, money.currency, money.percent) == (
        12_000_000, 9_150_000, "USD", 76,
    )  # fmt: skip
    assert [c.name for c in view.components][0] == "Road upgrading, Package 1"


def test_the_ratings_keep_their_own_scale(world):
    view = DashboardData(world.pool).project("manager-1", ROADS)

    assert view is not None
    ratings = {r.area: r for r in view.ratings}
    assert list(ratings)[0] == "Progress toward the objective"
    risk = ratings["Overall risk"]
    assert (risk.before, risk.now, risk.trend) == ("Substantial", "High", "worse")
    assert ratings["Procurement"].trend == "same"
    assert ratings["Financial management"].trend == "worse"
    assert view.ratings_as_of == "29 May 2026"


def test_the_reports_list(world):
    view = DashboardData(world.pool).project("manager-1", ROADS)

    assert view is not None and len(view.reports) == 1
    report = view.reports[0]
    assert report.status == "received" and report.approved_at == 1_794_268_800.0


def test_a_mission_with_no_pack_or_report_still_has_a_page(world):
    view = DashboardData(world.pool).project("manager-1", BRIDGES)

    assert view is not None and view.row.title == "Bridges" and view.reports == []
    assert view.ratings == [] and view.financing is None


def test_an_unknown_mission_is_none(world):
    assert DashboardData(world.pool).project("manager-1", "no-such-mission") is None
