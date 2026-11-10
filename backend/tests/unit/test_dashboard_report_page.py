"""The report page (#177): the aide-memoire's shape (header, ratings table, sections with numbered
sentences, the action plan with what the site walk saw); each number opens its proof; the badge says
"verified" only when the stored approval checks again with the kept key; strictly confidential
sentences reach only the `confidential` role; files are served only to a signed-in manager."""

import dataclasses

import pytest
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.approval_keys import key_id
from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.db.dashboard_project import Rating
from missioncopilot_backend.db.dashboard_report import (
    Action,
    KeptFile,
    Line,
    ProofFact,
    ReportView,
    Source,
)
from missioncopilot_backend.db.sync import StoredReport, StoredSentence
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.sync_batch import decode
from tests.unit.sync_batches import PhoneBatch
from tests.unit.test_dashboard_portfolio import ROADS

pytestmark = pytest.mark.unit

ORIGIN = "https://localhost"
DEVICE = "6f1d2c3a-0000-4000-8000-0000000000d1"
SHA = "a" * 64
FLAG_TEXT = "The payment ratio rule flagged contract 1."
PHONE = PhoneBatch(ROADS.id)
BODY = PHONE.body()


def stored() -> StoredReport:
    lines = [StoredSentence(s["id"], s["section"], s["text"], s["classification"],
                            tuple(s["factIds"])) for s in BODY["sentences"]]  # fmt: skip
    return StoredReport("draft-1", "en", "Officer <Kofi>", 1_794_268_800.0,
                        decode(BODY["approval"]["payload"]) or b"",
                        decode(BODY["approval"]["signature"]) or b"",
                        key_id(PHONE.approval_der), DEVICE, 1_794_270_000.0, lines)  # fmt: skip


PACK = Source(1, "pack", "2026-11-12T09:41:07Z",
              f"sections/agreed-actions.json#/actions/0 sha256:{SHA}", False,
              [("sections/agreed-actions.json#/actions/0",
                {"action": "Start the bridge", "responsible": "Contractor"})])  # fmt: skip
WALK = Source(2, "walk", "2026-11-12T09:42:07Z", "action:Start the bridge", True, [])
PHOTO = Source(3, "photo", "2026-11-12T09:43:07Z", None, True, [])
SCAN = Source(4, "scan", None, "vision-recognize-documents-1 text 120+9", True, [])
AUDIO = Source(5, "audio", None, "speech-1 text 40+12", True, [])
FLAG = ProofFact("fact-1", "flag:MC-01:0", "flag computed 1.4", None, "red-flag",
                 "strictly_confidential", [PACK])  # fmt: skip
ACTION = ProofFact("fact-2", "pack:sections/agreed-actions.json#/actions/0", "Start <the> bridge",
                   None, "pack-record", "official_use_only", [PACK])  # fmt: skip
SEEN = ProofFact("fact-3", "walk:action-Start the b", "seen: no; note: no works", None,
                 "walk-answer", "official_use_only", [WALK, PHOTO, SCAN, AUDIO])  # fmt: skip
VIEW = ReportView(
    row=ROADS,
    ratings=[Rating("Overall risk", "Substantial", "High", "worse")], ratings_as_of="29 May 2026",
    actions=[Action("Start the bridge", "Contractor", "31 Jul 2026", "Not started",
                    "seen: no; note: no works"),
             Action("Submit a plan", "Contractor", "15 Jul 2026", "Ongoing", None)],
    lines=[Line(1, "findings", FLAG_TEXT, "strictly_confidential", [FLAG]),
           Line(2, "agreedActions", "Start the Section 3 bridge works.", "official_use_only",
                [ACTION]),
           Line(3, "agreedActions", "The site walk saw <no> works.", "official_use_only", [SEEN])],
    stored=stored(),
)  # fmt: skip
FILES = {3: KeptFile("photo", b"\xff\xd8\xff\xe0 photo", False),
         4: KeptFile("scan", b"\x89PNG\r\n\x1a\n page", True),
         5: KeptFile("audio", b"\x00\x00\x00\x18ftypM4A rec", False),
         6: KeptFile("photo", b"<svg onload=alert(1)>", False)}  # fmt: skip


def client(view=VIEW, roles=("manager",), key=True, signed_in=True) -> TestClient:
    store = DashboardMemory()
    app = create_app(Settings(environment="test", dashboard_origin=ORIGIN), dashboard=store)
    reader = type("R", (), {
        "report": lambda _, m, mission: view,
        "project": lambda _, m, mission: None,
        "evidence_file": lambda _, m, mission, seq: FILES.get(seq) if mission == ROADS.id else None,
    })()  # fmt: skip
    app.state.dashboard_reader = lambda org: reader
    if key:
        app.state.approval_keys.add(DEVICE, PHONE.approval_der)
    made = TestClient(app, base_url=ORIGIN, follow_redirects=False)
    user = store.add_user("org-a", "manager-1", "Amina Diallo", roles)
    if signed_in:
        made.cookies.set("__Host-mc_session", store.new_session(user.id))
    return made


def page(**kw) -> str:
    return client(**kw).get(f"/dashboard/missions/{ROADS.id}/report").text


def test_the_aide_memoire_shape():
    html = page(roles=("manager", "confidential"))
    assert "Aide-memoire" in html and "Kandor Rural Roads Project, Package 1" in html
    assert html.index("Ratings <b>now and before</b>") < html.index("Main findings")
    assert html.index("Main findings") < html.index("Agreed actions")
    assert "Overall risk" in html and 'class="trend worse"' in html
    assert "The site walk saw &lt;no&gt; works." in html and "<no>" not in html  # escaped


def test_the_action_plan_shows_what_the_walk_saw():
    html = page()
    assert "What the site walk saw" in html
    assert "31 Jul 2026" in html and "Not started" in html and "seen: no; note: no works" in html
    assert "Not checked on this visit" in html  # the second action


def test_each_number_opens_its_proof_without_script():
    html = page()
    assert 'popovertarget="proof-2"' in html and 'id="proof-2" popover' in html
    assert "Mission pack record" in html and "responsible" in html and "Contractor" in html
    assert "sections/agreed-actions.json#/actions/0" in html
    assert "Start &lt;the&gt; bridge" in html


def test_files_open_inside_the_proof():
    html = page()
    src = f"/dashboard/missions/{ROADS.id}/evidence"
    assert f'<img loading="lazy" src="{src}/3"' in html
    assert f'<img loading="lazy" src="{src}/4"' in html and "120+9" in html
    assert f'<audio controls preload="none" src="{src}/5"' in html and "40+12" in html
    assert "Agreed action: Start the bridge" in html


def test_strictly_confidential_words_reach_only_the_confidential_role():
    plain = page()
    assert FLAG_TEXT not in plain and "flag computed 1.4" not in plain
    assert "Strictly confidential: not shown for your role." in plain
    assert 'popovertarget="proof-1"' not in plain
    cleared = page(roles=("manager", "confidential"))
    assert FLAG_TEXT in cleared and "flag computed 1.4" in cleared


def test_a_confidential_fact_inside_an_open_sentence_is_hidden_too():
    line = dataclasses.replace(VIEW.lines[1], facts=[ACTION, FLAG])
    view = dataclasses.replace(VIEW, lines=[VIEW.lines[0], line, VIEW.lines[2]])
    plain = page(view=view)
    assert "flag computed 1.4" not in plain and "Start &lt;the&gt; bridge" in plain


def test_the_badge_is_verified_with_the_kept_key():
    html = page()
    assert 'class="seal ok"' in html and "Signed with Face ID on the officer's iPhone" in html
    assert "verified by the server" in html and "Officer &lt;Kofi&gt;" in html


def test_a_tampered_row_or_a_missing_key_is_not_verified():
    first = dataclasses.replace(VIEW.stored.sentences[0], text="All works done.")
    tampered = dataclasses.replace(
        VIEW, stored=dataclasses.replace(VIEW.stored, sentences=[first, *VIEW.stored.sentences[1:]])
    )
    for html in (page(view=tampered), page(key=False)):
        assert 'class="seal bad"' in html and "Not verified" in html
        assert "verified by the server" not in html


def test_a_print_button_and_the_print_look():
    html = page()
    assert 'data-action="print"' in html and "/dashboard/static/report.css" in html
    assert f'href="/dashboard/missions/{ROADS.id}/trail"' in html  # #178


def test_no_report_is_404_and_signed_out_goes_to_sign_in():
    assert client(view=None).get(f"/dashboard/missions/{ROADS.id}/report").status_code == 404
    gone = client(signed_in=False).get(f"/dashboard/missions/{ROADS.id}/report")
    assert gone.status_code == 303 and gone.headers["location"] == "/dashboard/sign-in"


def test_a_mission_link_always_opens_its_project_page():
    """Lubo, Nov 10: one fixed path (missions, project, report, trail), never "sometimes"."""
    for view in (VIEW, None):
        opened = client(view=view).get(f"/dashboard/missions/{ROADS.id}")
        assert opened.headers["location"] == f"/dashboard/missions/{ROADS.id}/project"


def test_the_one_way_back_goes_to_the_project():
    html = page()
    assert f'class="back" href="/dashboard/missions/{ROADS.id}/project"' in html
    assert 'aria-label="Back"' in html and 'class="crumbs"' not in html


def test_a_kept_file_is_served_privately_with_its_sniffed_type():
    made = client()
    photo = made.get(f"/dashboard/missions/{ROADS.id}/evidence/3")
    assert photo.status_code == 200 and photo.headers["content-type"] == "image/jpeg"
    assert "no-store" in photo.headers["cache-control"]
    assert photo.headers["x-content-type-options"] == "nosniff"
    audio = made.get(f"/dashboard/missions/{ROADS.id}/evidence/5")
    assert audio.headers["content-type"] == "audio/mp4"


def test_an_unknown_type_a_missing_file_or_no_session_is_refused():
    made = client()
    assert made.get(f"/dashboard/missions/{ROADS.id}/evidence/6").status_code == 404
    assert made.get(f"/dashboard/missions/{ROADS.id}/evidence/9").status_code == 404
    assert made.get("/dashboard/missions/other/evidence/3").status_code == 404
    out = client(signed_in=False).get(f"/dashboard/missions/{ROADS.id}/evidence/3")
    assert out.status_code == 401


def test_a_file_only_red_flags_cite_needs_the_confidential_role():
    assert client().get(f"/dashboard/missions/{ROADS.id}/evidence/4").status_code == 404
    cleared = client(roles=("manager", "confidential"))
    seen = cleared.get(f"/dashboard/missions/{ROADS.id}/evidence/4")
    assert seen.status_code == 200 and seen.headers["content-type"] == "image/png"
