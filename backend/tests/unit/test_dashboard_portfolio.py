"""The portfolio page (#175, steps 8.5.0 to 8.5.3): the manager's first screen. In the bank's own
reading order: a navy band with the brand, "MISSIONS TO REVIEW", three numbers, the missions table
and the site visits; with the luxury touches (edge cards, the medallion's shine, the radar) and the
Command-K palette. Every value is escaped; status and risk are never colour alone."""

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.db.dashboard_data import MissionRow, Portfolio
from missioncopilot_backend.settings import Settings

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
ROADS = MissionRow(
    id="6f1d2c3a-0000-4000-8000-000000000001", title="Kandor Rural Roads Project, Package 1",
    country="Kandor", sector="Transport: rural roads", project_ref="KRRP-P1", status="received",
    risk_now="High", risk_before="Substantial", red_flags=2, sentences=51,
    received_at=1_794_270_000.0, approved_at=1_794_268_800.0, points=[(41.86, -87.71, 6.8)],
)  # fmt: skip
BRIDGES = MissionRow(
    id="6f1d2c3a-0000-4000-8000-000000000002", title="Bridges <&> \"repair\"", country=None,
    sector=None, project_ref=None, status="in_field", risk_now=None, risk_before=None,
    red_flags=0, sentences=0, received_at=None, approved_at=None,
)  # fmt: skip


def client_with(portfolio: Portfolio) -> TestClient:
    store = DashboardMemory()
    app = create_app(Settings(environment="test", dashboard_origin=ORIGIN), dashboard=store)
    app.state.dashboard_reader = lambda org_id: type(
        "R", (), {"portfolio": lambda _, m: portfolio}
    )()
    client = TestClient(app, base_url=ORIGIN)
    user = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    client.cookies.set("__Host-mc_session", store.new_session(user.id))
    return client


@pytest.fixture
def page() -> str:
    return (
        client_with(Portfolio([ROADS, BRIDGES], to_review=1, red_flags=2, endorsed=0))
        .get("/dashboard")
        .text
    )


def test_the_bank_reading_order(page):
    for part in ('class="band"', '<h1 class="caps">Missions <b>to review</b></h1>',
                 'data-count="1"', "Reports to review", 'data-count="2"', "Red flags raised",
                 'data-count="0"', "Endorsed", 'class="missions"',
                 "Site <b>visits</b>"):  # fmt: skip
        assert part in page, part
    assert page.index('class="stats"') < page.index('class="missions"')


def test_each_mission_is_a_row_with_words_not_only_colour(page):
    mission = "/dashboard/missions/6f1d2c3a-0000-4000-8000-000000000001"
    assert f'class="mission-link" href="{mission}/project"' in page  # the name: the project
    assert f'class="review-link" href="{mission}/report"' in page  # to review: the report
    assert "KRRP-P1" in page and "Kandor" in page
    assert 'class="status received"' in page and "Received, to review" in page
    assert 'class="status in_field"' in page and "In the field" in page
    assert "High" in page and "up from Substantial" in page and 'class="trend up"' in page


def test_every_value_is_escaped(page):
    assert "Bridges &lt;&amp;&gt; &quot;repair&quot;" in page
    assert "<&>" not in page


def test_the_brand_shines_like_the_iphone(page):
    assert 'class="medallion shine"' in page and 'src="/dashboard/static/logo.png"' in page


def test_the_site_visits_radar_prints_no_coordinates(page):
    assert 'class="radar"' in page and "1 sample point" in page and "within 7 m" in page
    assert "41.86" not in page and "-87.71" not in page


def test_the_command_k_palette_lists_every_mission(page):
    assert '<dialog id="palette"' in page and 'aria-keyshortcuts="Meta+K Control+K"' in page
    assert page.count('class="palette-item"') >= 2


def test_no_mission_yet_is_said_plainly():
    page = client_with(Portfolio([], 0, 0, 0)).get("/dashboard").text

    assert "No mission yet" in page


def test_the_shared_styles_are_linked(page):
    assert '<link rel="stylesheet" href="/dashboard/static/dashboard.css">' in page
    assert '<link rel="stylesheet" href="/dashboard/static/pages.css">' in page
