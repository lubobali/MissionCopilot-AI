"""The project page (#176, step 8.6.2): a fact sheet from the pack, financing with a disbursed bar,
the ratings table in the bank's own words, components, and the mission's reports listed like a
documents list. Every value escaped; trends in words, not colour alone."""

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.db.dashboard_project import (
    Component,
    Financing,
    ProjectView,
    Rating,
    ReportEntry,
)
from missioncopilot_backend.settings import Settings
from tests.unit.test_dashboard_portfolio import ROADS

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
VIEW = ProjectView(
    row=ROADS, facts={"Reference": "KRRP-P1", "Implementing agency": "Ministry <of> Works"},
    objective="Improve all-season road access.", financing=Financing(12_000_000, 9_150_000, "USD"),
    components=[Component("Road upgrading, Package 1", 10_000_000, 8_500_000)],
    ratings=[Rating("Overall risk", "Substantial", "High", "worse"),
             Rating("Procurement", "Satisfactory", "Satisfactory", "same")],
    ratings_as_of="29 May 2026",
    reports=[ReportEntry("draft-1", "received", 1_794_268_800.0, 1_794_270_000.0)],
)  # fmt: skip


def client(view: ProjectView | None) -> TestClient:
    store = DashboardMemory()
    app = create_app(Settings(environment="test", dashboard_origin=ORIGIN), dashboard=store)
    reader = type("R", (), {"project": lambda _, m, mission: view})()
    app.state.dashboard_reader = lambda org: reader
    made = TestClient(app, base_url=ORIGIN)
    user = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    made.cookies.set("__Host-mc_session", store.new_session(user.id))
    return made


@pytest.fixture
def page() -> str:
    return client(VIEW).get(f"/dashboard/missions/{ROADS.id}/project").text


def test_a_fact_sheet_from_the_pack(page):
    assert 'class="back" href="/dashboard"' in page and 'aria-label="Back"' in page
    assert "Kandor Rural Roads Project, Package 1" in page and "KRRP-P1" in page
    assert "Ministry &lt;of&gt; Works" in page and "Improve all-season road access." in page


def test_financing_says_its_number_in_words_too(page):
    assert "USD 9,150,000 of USD 12,000,000 disbursed (76%)" in page
    assert '<meter class="bar" min="0" max="100" value="76"' in page


def test_the_ratings_table_in_the_banks_words(page):
    assert '<h2 class="caps small">Ratings <b>now and before</b></h2>' in page
    assert "Overall risk" in page and "Substantial" in page and "High" in page
    assert 'class="trend worse"' in page and "Worse" in page and "Same" in page
    assert "As of 29 May 2026" in page


def test_the_reports_listed_like_documents(page):
    assert "Mission <b>reports</b>" in page
    assert "Aide-memoire" in page and "Received, to review" in page
    assert f'href="/dashboard/missions/{ROADS.id}/report"' in page


def test_an_unknown_mission_is_404():
    assert client(None).get(f"/dashboard/missions/{ROADS.id}/project").status_code == 404
