"""The decision panel and the audit trail page (#178): endorse with Touch ID or send back with a
note, or what was decided; the reason instead of buttons for a team member or an unverified report;
every step in time order, and "Chain intact" only when the audit log verifies again."""

import dataclasses

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.dashboard_decision import panel
from missioncopilot_backend.db.dashboard_report import Trail, Version
from missioncopilot_backend.db.reviews import Review
from missioncopilot_backend.settings import Settings
from tests.unit.test_dashboard_report_page import DEVICE, PHONE, VIEW

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
BACK = Review(1, "sent_back", "Check <the> bridge numbers.", "manager-2", "Kwame Asante",
              1_794_280_000.0, "a" * 64)  # fmt: skip
DONE = Review(2, "endorsed", None, "manager-1", "Amina Diallo", 1_794_290_000.0, "b" * 64)


def test_a_report_to_decide_offers_touch_id_and_a_note():
    html = panel(VIEW, verified=True)
    assert 'data-action="endorse"' in html and "Endorse with Touch ID" in html
    assert f'action="/v1/dashboard/missions/{VIEW.row.id}/send-back"' in html
    assert 'name="note" required maxlength="500"' in html


def test_a_decided_report_says_who_and_when_and_offers_nothing():
    endorsed = panel(
        dataclasses.replace(VIEW, reviews=[dataclasses.replace(DONE, version=1)]), True
    )
    assert "Endorsed</b> with Touch ID by Amina Diallo" in endorsed
    assert 'data-action="endorse"' not in endorsed
    back = panel(dataclasses.replace(VIEW, reviews=[BACK]), True)
    assert "Sent back to the officer" in back and "Check &lt;the&gt; bridge numbers." in back
    assert "/send-back" not in back and 'data-action="endorse"' not in back
    assert "Version 1 sent back by" not in back  # the current version's own, said once above


def test_a_team_member_or_an_unverified_report_gets_the_reason():
    team = panel(dataclasses.replace(VIEW, on_team=True), True)
    assert "separation of duties" in team and 'data-action="endorse"' not in team
    unverified = panel(VIEW, verified=False)
    assert "cannot be endorsed" in unverified and 'data-action="endorse"' not in unverified


def test_a_newer_version_shows_why_the_last_was_sent_back():
    second = dataclasses.replace(VIEW, stored=dataclasses.replace(VIEW.stored, version=2),
                                 reviews=[BACK])  # fmt: skip
    html = panel(second, True)
    assert "Version 2" in html and "Version 1 sent back by Kwame Asante" in html
    assert 'data-action="endorse"' in html  # version 2 waits for its own decision


def client(trail, log: AuditLog) -> TestClient:
    store = DashboardMemory()
    app = create_app(Settings(environment="test", dashboard_origin=ORIGIN), dashboard=store,
                     audit=log)  # fmt: skip
    app.state.dashboard_reader = lambda org: type("R", (), {
        "trail": lambda _, m, mission: trail, "report": lambda _, m, mission: VIEW})()  # fmt: skip
    app.state.approval_keys.add(DEVICE, PHONE.approval_der)
    made = TestClient(app, base_url=ORIGIN, follow_redirects=False)
    user = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    made.cookies.set("__Host-mc_session", store.new_session(user.id))
    return made


TRAIL = Trail(VIEW.row, [Version(1, "draft-1", "Kofi Mensah", 1_794_250_000.0, 1_794_260_000.0),
                         Version(2, "draft-2", "Kofi Mensah", 1_794_285_000.0, 1_794_286_000.0)],
              [BACK, DONE])  # fmt: skip


def test_the_trail_lists_every_step_in_order_with_the_log():
    log = AuditLog(clock=lambda: 1_794_261_000.0)
    log.record("mission_synced", org_id="org-a", actor="officer-7", subject=VIEW.row.id)
    log.record("mission_synced", org_id="org-b", actor="x", subject=VIEW.row.id)  # another org

    html = client(TRAIL, log).get(f"/dashboard/missions/{VIEW.row.id}/trail").text

    order = [
        "Version 1 approved with Face ID",
        "Version 1 received",
        "Report sent from the iPhone",
        "Version 1 sent back",
        "Version 2 approved",
        "Version 2 endorsed with Touch ID",
    ]
    assert [html.index(words) for words in order] == sorted(html.index(w) for w in order)
    assert html.count("Report sent from the iPhone") == 1
    assert "officer-7" not in html and "The officer&#x27;s iPhone" in html  # names, never ids
    assert "Kofi Mensah" in html and "draft-1" not in html  # a name as written; no draft ids
    assert "Check &lt;the&gt; bridge numbers." in html
    assert 'class="seal ok"' in html and "Chain intact" in html and "2 log entries" in html


def test_a_changed_log_entry_breaks_the_chain():
    log = AuditLog()
    log.record("mission_synced", org_id="org-a", subject=VIEW.row.id)
    log.record("report_endorsed", org_id="org-a", subject=VIEW.row.id)
    log._events[0] = log._events[0].replace(actor="someone else")  # noqa: SLF001 - the tamper

    html = client(TRAIL, log).get(f"/dashboard/missions/{VIEW.row.id}/trail").text

    assert 'class="seal bad"' in html and "Chain broken" in html and "entry 0 was changed" in html
    assert "Chain intact" not in html


def test_the_one_way_back_goes_to_the_report():
    html = client(TRAIL, AuditLog()).get(f"/dashboard/missions/{VIEW.row.id}/trail").text
    assert f'class="back" href="/dashboard/missions/{VIEW.row.id}/report"' in html


def test_an_unknown_mission_is_404():
    assert (
        client(None, AuditLog()).get(f"/dashboard/missions/{VIEW.row.id}/trail").status_code == 404
    )
