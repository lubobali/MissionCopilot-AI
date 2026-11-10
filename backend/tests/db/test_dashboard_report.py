"""The report page's data (#177, step 8.7.1): rebuilt from what the phone signed and sent, read as
a manager: each sentence with its number, section and facts, each fact with its evidence (the pack
record the region points at, the kept files), and the action plan. A mission with no report, or
not the organization's, is none."""

from collections.abc import Iterator

import psycopg
import pytest

from missioncopilot_backend.db.dashboard_data import DashboardData
from tests.db.dashboard_world import ACTION, BRIDGES, ROADS, DashboardWorld, dashboard_world

pytestmark = pytest.mark.db


@pytest.fixture
def world() -> Iterator[DashboardWorld]:
    yield from dashboard_world()


def test_the_sentences_keep_number_section_and_facts(world):
    view = DashboardData(world.pool).report("manager-1", ROADS)

    assert view is not None
    assert [(line.number, line.section, line.classification) for line in view.lines] == [
        (1, "findings", "strictly_confidential"), (2, "agreedActions", "official_use_only"),
        (3, "agreedActions", "official_use_only"),
    ]  # fmt: skip
    assert view.lines[1].text == "Start the Section 3 bridge works."
    assert [f.rule for f in view.lines[2].facts] == ["walk-answer"]
    assert view.stored.approved_by == "this-phone"


def test_each_fact_keeps_its_evidence(world):
    view = DashboardData(world.pool).report("manager-1", ROADS)

    assert view is not None
    record = view.lines[1].facts[0].sources[0]
    assert (record.seq, record.kind, record.has_file) == (1, "pack", False)
    found = record.records[0][1]
    assert isinstance(found, dict) and found["action"] == ACTION
    walk, photo = view.lines[2].facts[0].sources
    assert (walk.kind, walk.region, photo.kind, photo.has_file) == (
        "walk", f"action:{ACTION}", "photo", True,
    )  # fmt: skip
    assert photo.captured_at == "2026-11-12T09:43:07Z"


def test_the_action_plan_with_what_the_walk_saw(world):
    view = DashboardData(world.pool).report("manager-1", ROADS)

    assert view is not None
    first = view.actions[0]
    assert (first.action, first.deadline, first.seen) == (
        ACTION, "31 Jul 2026", "seen: no; note: no works on site",
    )  # fmt: skip
    assert view.actions[1].seen is None
    assert [r.area for r in view.ratings][-1] == "Overall risk"


def test_no_report_or_another_mission_is_none(world):
    data = DashboardData(world.pool)

    assert data.report("manager-1", BRIDGES) is None
    assert data.report("manager-1", "6f1d2c3a-0000-4000-8000-000000000009") is None


def test_a_kept_file_by_seq(world):
    data = DashboardData(world.pool)

    kept = data.evidence_file("manager-1", ROADS, 3)
    assert kept is not None and kept.kind == "photo" and kept.data.startswith(b"\xff\xd8")
    assert not kept.confidential_only  # cited by a fact that is not strictly confidential
    assert data.evidence_file("manager-1", ROADS, 1) is None  # the pack's file is not kept
    assert data.evidence_file("manager-1", BRIDGES, 3) is None


def test_the_trail_lists_every_version_and_decision(world):
    from missioncopilot_backend.db.reviews import Reviews

    Reviews(world.pool).decide(
        "manager-1", "Amina", ROADS, 1, "sent_back", "Check it.", "c" * 64, 9.0
    )

    trail = DashboardData(world.pool).trail("manager-1", ROADS)

    assert trail is not None
    assert [(v.version, v.draft_id, v.approved_by) for v in trail.versions] == [
        (1, "draft-1", "this-phone"),
    ]  # fmt: skip
    assert [(r.version, r.decision, r.note) for r in trail.reviews] == [
        (1, "sent_back", "Check it.")
    ]
    assert (
        DashboardData(world.pool).trail("manager-1", "6f1d2c3a-0000-4000-8000-000000000009") is None
    )


def test_a_walk_answer_that_is_a_photo_brings_that_photo(world):
    """The phone answers a photo question with "evidence:N"; the proof shows item N with it."""
    from missioncopilot_backend.db.dashboard_report import facts

    with psycopg.connect(world.admin) as conn:
        conn.execute("ALTER TABLE facts DISABLE TRIGGER no_update_or_delete")
        conn.execute("UPDATE facts SET value = 'evidence:3' WHERE id = 'fact-3'")
        conn.execute("ALTER TABLE facts ENABLE TRIGGER no_update_or_delete")
        found = facts(conn, ROADS)["fact-3"]

    assert [(s.seq, s.region, s.has_file) for s in found.sources] == [
        (2, f"action:{ACTION}", True), (3, None, True),
    ]  # fmt: skip  # already cited: not twice
    with psycopg.connect(world.admin) as conn:
        conn.execute("ALTER TABLE facts DISABLE TRIGGER no_update_or_delete")
        conn.execute("UPDATE facts SET value = 'evidence:1' WHERE id = 'fact-3'")
        conn.execute("ALTER TABLE facts ENABLE TRIGGER no_update_or_delete")
        found = facts(conn, ROADS)["fact-3"]
    assert (found.sources[-1].seq, found.sources[-1].region) == (1, "answer")
