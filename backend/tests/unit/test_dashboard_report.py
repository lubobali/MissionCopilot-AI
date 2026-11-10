"""The report page's helpers (#177, step 8.7.1): a pack region names the exact file and a JSON
pointer into it; the action plan joins the pack's agreed actions with what the site walk saw."""

import pytest

from missioncopilot_backend.db.dashboard_report import (
    ProofFact,
    Source,
    pack_places,
    pointer,
    seen_for,
)

pytestmark = pytest.mark.unit

SHA = "a" * 64


def test_a_json_pointer_finds_the_record():
    doc = {"actions": [{"action": "Start"}, {"a/b": 1, "m~n": 2, "~1": 3}]}

    assert pointer(doc, "/actions/0") == {"action": "Start"}
    assert pointer(doc, "/actions/1/a~1b") == 1
    assert pointer(doc, "/actions/1/m~0n") == 2
    assert pointer(doc, "/actions/1/~01") == 3  # RFC 6901: ~1 first, then ~0
    assert pointer(doc, "") == doc
    assert pointer(doc, "/actions/9") is None
    assert pointer(doc, "/actions/x") is None
    assert pointer(doc, "/missing") is None


def test_a_pack_region_names_file_pointer_and_hash():
    region = f"sections/agreed-actions.json#/actions/0 sha256:{SHA}"

    assert pack_places(region) == [("sections/agreed-actions.json", "/actions/0", SHA)]


def test_a_paid_sum_and_merged_regions_are_read():
    region = (
        f"sections/contracts.json#/contracts/0/payments sum sha256:{SHA} | b.json#/x sha256:{SHA}"
    )

    assert pack_places(region) == [
        ("sections/contracts.json", "/contracts/0/payments", SHA), ("b.json", "/x", SHA),
    ]  # fmt: skip


@pytest.mark.parametrize("region", [None, "question:bridge", "vision text 4+9", "a.json#/x"])
def test_other_regions_are_not_pack_places(region):
    assert pack_places(region) == []


def walk_check(action: str, seen: str) -> ProofFact:
    source = Source(2, "walk", None, f"action:{action}", False, [])
    return ProofFact("f", "walk:action-x", seen, None, "walk-answer", "official_use_only", [source])


def test_the_action_plan_shows_what_the_walk_saw():
    section = {"actions": [
        {"action": "Start the bridge", "responsible": "Contractor", "deadline": "2026-07-31",
         "status": "Not started"},
        {"action": "Submit a plan", "responsible": "Contractor", "deadline": "2026-07-15",
         "status": "Ongoing"},
    ]}  # fmt: skip

    actions = seen_for(section, [walk_check("Start the bridge", "seen: no")])

    assert [(a.action, a.responsible, a.deadline, a.status, a.seen) for a in actions] == [
        ("Start the bridge", "Contractor", "31 Jul 2026", "Not started", "seen: no"),
        ("Submit a plan", "Contractor", "15 Jul 2026", "Ongoing", None),
    ]  # fmt: skip


def test_a_broken_action_section_gives_no_actions():
    assert seen_for({"actions": "x"}, []) == []
    assert seen_for({"actions": ["x", {"action": 3}]}, []) == []
