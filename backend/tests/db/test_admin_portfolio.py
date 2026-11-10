"""The rest of the fictional Kandor portfolio (Lubo, Nov 10): seed-demo adds five more missions and
publish-demo-pack their signed packs, so a manager's portfolio looks like one; they are in the
field, with their own ratings and money, and no phone of the demo's officers sees them."""

import pytest
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend import admin
from missioncopilot_backend.admin_portfolio import PROJECTS, TEAM, mission_id
from missioncopilot_backend.db.dashboard_data import DashboardData
from missioncopilot_backend.db.organizations import names_for
from missioncopilot_backend.server import build
from tests.db.postgres import admin_url
from tests.db.test_admin import _server_env, ops  # noqa: F401 - the fixture
from tests.unit.clients import local_client

pytestmark = pytest.mark.db


def test_the_portfolio_has_seven_missions_and_the_officers_phones_see_only_theirs(ops):  # noqa: F811
    admin.setup(admin_url(), ops.secrets, ops.directory)
    demo = ops.org()
    admin.seed_demo(admin_url(), ops.secrets, demo)
    key = ops.secrets.parent / "keys" / "signing-key.pem"
    admin.make_signing_key(key)
    admin.publish_demo_pack(admin_url(), key, demo)
    admin.publish_demo_pack(admin_url(), key, demo)  # safe to run again: next versions

    with ConnectionPool(make_conninfo(admin_url(), dbname=names_for(demo)[0]), open=True) as pool:
        portfolio = DashboardData(pool).portfolio("manager-1")
    rows = {row.id: row for row in portfolio.rows}
    assert len(rows) == 7
    water = rows[mission_id("3")]
    assert (water.title, water.project_ref, water.status) == (
        "Kandor Water Supply and Sanitation", "KWSS-P2", "in_field",
    )  # fmt: skip
    assert (water.risk_before, water.risk_now) == ("Substantial", "Moderate")
    assert all(rows[mission_id(p[0])].risk_now for p in PROJECTS)

    app = build(_server_env(ops))
    with local_client(app):
        store = app.state.databases.for_org(demo)
        assert [m.id for m in store.for_user("officer-7")] == [admin.ROADS, admin.BRIDGES]
        assert len(store.for_user(TEAM)) == len(PROJECTS)
