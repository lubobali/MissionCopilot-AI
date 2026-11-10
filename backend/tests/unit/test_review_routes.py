"""Endorse and send back from the report page (#178, steps 8.8.1-8.8.2): only the newest report,
verified again, not yet decided, by a manager not on the team; endorse needs the manager's own
passkey with Touch ID over a challenge naming this report; send back needs a note. Both final and
audited; the dashboard's own Origin and a session, or nothing."""

import dataclasses

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.db.reviews import Decided, Review, approval_hash
from missioncopilot_backend.passkeys import Site, registration_options, verify_registration
from missioncopilot_backend.settings import Settings
from tests.unit.soft_authenticator import UP, UV, SoftAuthenticator
from tests.unit.test_dashboard_report_page import DEVICE, PHONE, VIEW

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
SITE = Site(rp_id="localhost", origin=ORIGIN)
MISSION = VIEW.row.id
BASE = f"/v1/dashboard/missions/{MISSION}"


class Decider:
    def __init__(self) -> None:
        self.made: list[tuple] = []

    def decide(
        self, manager_id, name, mission_id, version, decision, note, hashed, at, assertion=None
    ):
        if self.made:
            raise Decided
        self.made.append((manager_id, mission_id, version, decision, note, hashed, assertion))
        return Review(version, decision, note, manager_id, name, at, hashed)


class World:
    def __init__(self, view=VIEW):
        self.store, self.log, self.decider = DashboardMemory(), AuditLog(), Decider()
        settings = Settings(environment="test", dashboard_origin=ORIGIN)
        app = create_app(settings, dashboard=self.store, audit=self.log)
        app.state.dashboard_reader = lambda org: type("R", (), {"report": lambda _, m, mi: view})()
        app.state.dashboard_decider = lambda org: self.decider
        app.state.approval_keys.add(DEVICE, PHONE.approval_der)
        self.client = TestClient(app, base_url=ORIGIN, follow_redirects=False)
        self.user = self.store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
        code, _ = self.store.issue_invite(self.user.id)
        self.key = SoftAuthenticator("localhost", ORIGIN)
        options = registration_options(self.store, code, SITE)
        verify_registration(self.store, self.key.create(options), SITE)
        self.client.cookies.set("__Host-mc_session", self.store.new_session(self.user.id))

    def post(self, path, headers=None, **kw):
        sent = {"Origin": ORIGIN, "Content-Type": "application/x-www-form-urlencoded"}
        return self.client.post(BASE + path, headers=sent | (headers or {}), **kw)

    def endorse(self, flags=UP | UV):
        options = self.post("/endorse/options")
        assert options.status_code == 200, options.text
        answer = {"credential": self.key.get(options.text, flags=flags)}
        return self.post("/endorse", json=answer, headers={"Content-Type": "application/json"})


def test_touch_id_endorses_the_newest_report_once():
    world = World()

    done = world.endorse()

    assert done.status_code == 201 and done.json() == {"decision": "endorsed", "version": 1}
    manager, mission, version, decision, note, hashed, assertion = world.decider.made[0]
    assert (manager, mission, version, decision, note) == (
        "manager-1",
        MISSION,
        1,
        "endorsed",
        None,
    )
    assert hashed == approval_hash(VIEW.stored.approval_payload) and assertion.signature
    assert [e.kind for e in world.log.events()][-1] == "report_endorsed"


def test_without_touch_id_nothing_is_endorsed():
    world = World()

    assert world.endorse(flags=UP).status_code == 401
    assert world.decider.made == []


def test_a_decided_report_is_final():
    reviewed = Review(1, "sent_back", "Check it.", "manager-2", "B", 1.0, "a" * 64)
    world = World(dataclasses.replace(VIEW, reviews=[reviewed]))

    options = world.post("/endorse/options")
    assert options.status_code == 409 and options.json()["detail"] == "review:already_decided"
    assert world.post("/send-back", content="note=again").status_code == 409


def test_a_manager_on_the_team_cannot_decide():
    world = World(dataclasses.replace(VIEW, on_team=True))

    assert world.post("/endorse/options").status_code == 403
    assert world.post("/send-back", content="note=x").status_code == 403


def test_an_unverified_report_cannot_be_endorsed():
    first = dataclasses.replace(VIEW.stored.sentences[0], text="All works done.")
    tampered = dataclasses.replace(VIEW.stored, sentences=[first, *VIEW.stored.sentences[1:]])
    world = World(dataclasses.replace(VIEW, stored=tampered))

    found = world.post("/endorse/options")
    assert found.status_code == 409 and found.json()["detail"] == "review:not_verified"


def test_send_back_keeps_the_note_and_returns_to_the_report():
    world = World()

    sent = world.post("/send-back", content="note=Check+the+bridge+numbers.")

    assert sent.status_code == 303
    assert sent.headers["location"] == f"/dashboard/missions/{MISSION}/report"
    assert world.decider.made[0][3:5] == ("sent_back", "Check the bridge numbers.")
    assert [e.kind for e in world.log.events()][-1] == "report_sent_back"


@pytest.mark.parametrize("body", ["note=", "note=+++", "other=x", "note=" + "x" * 501])
def test_send_back_needs_a_note_of_1_to_500(body):
    world = World()

    assert world.post("/send-back", content=body).status_code == 422
    assert world.decider.made == []


def test_another_origin_or_no_session_decides_nothing():
    world = World()

    evil = world.post("/send-back", content="note=x", headers={"Origin": "https://evil.example"})
    assert evil.status_code == 403
    world.client.cookies.clear()
    assert world.post("/endorse/options").status_code == 401
    assert world.decider.made == []
