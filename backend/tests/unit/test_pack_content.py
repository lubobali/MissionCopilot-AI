"""The Kandor mission pack's files (#89): built from the demo dataset, every section matches its
schema (docs/api/pack-sections.schema.json), the story's facts arrive unchanged, and the whole pack
passes the pack format's own limits."""

import json
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from missioncopilot_backend.pack_content import SECTIONS, milestone_status, pack_files
from missioncopilot_backend.pack_format import build_manifest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
DATA = json.loads((ROOT / "docs" / "demo" / "kandor-rural-roads.json").read_text(encoding="utf-8"))
SCHEMA = json.loads(
    (ROOT / "docs" / "api" / "pack-sections.schema.json").read_text(encoding="utf-8")
)
FILES = pack_files(DATA)


def _section(name: str) -> dict:
    return json.loads(FILES[f"sections/{name}.json"])


def _errors(name: str, body: object) -> list:
    validator = Draft202012Validator(SCHEMA | {"$ref": f"#/$defs/{name}"})
    return list(validator.iter_errors(body))


def test_the_pack_has_nine_sections_a_checklist_and_two_documents():
    assert sorted(FILES) == sorted(
        [f"sections/{name}.json" for name in SECTIONS]
        + ["forms/road-checklist.json"]
        + ["documents/aide-memoire-2026-05.md", "documents/progress-report-2026-09.md"]
    )
    assert len(SECTIONS) == 9


@pytest.mark.parametrize("name", SECTIONS)
def test_every_section_matches_its_schema(name):
    assert _errors(name, _section(name)) == []


def test_the_checklist_matches_its_schema_and_is_koboStyle():
    form = json.loads(FILES["forms/road-checklist.json"])

    assert _errors("road-checklist", form) == []
    assert {row["name"] for row in form["survey"]} >= {"bridge_started", "road_width_m"}
    assert {c["list_name"] for c in form["choices"]} == {"yes_no"}


@pytest.mark.parametrize(
    ("name", "bad"),
    [
        ("ratings", {"pdoProgress": {"previous": "Good", "current": "Satisfactory"}}),
        ("ratings", {"overallRisk": {"previous": "Medium", "current": "High"}}),
        ("project", {"extra": "field"}),
        (
            "agreed-actions",
            {
                "actions": [
                    {"action": "x", "responsible": "y", "deadline": "soon", "status": "Done"}
                ]
            },
        ),  # fmt: skip
        ("financing", {"disbursed": -1}),
    ],
)
def test_the_schema_refuses_what_the_app_could_not_read(name, bad):
    assert _errors(name, _section(name) | bad) != []


def test_the_storys_money_arrives_unchanged():
    contract = _section("contracts")["contracts"][0]
    paid = sum(p["amount"] for p in contract["payments"])

    assert (contract["contractValue"], paid) == (10_000_000, 8_500_000)  # 85% paid
    assert contract["physicalProgress"]["kmBuilt"] * 2 == contract["physicalProgress"]["kmTotal"]
    assert contract["supplier"] == "Kandor Roadworks Ltd"


def test_financing_adds_up():
    financing = _section("financing")

    assert financing["disbursed"] == 9_150_000
    assert financing["undisbursed"] == financing["revised"] - financing["disbursed"]


def test_the_bridge_milestone_is_not_met_and_the_completion_is_still_scheduled():
    status = {m["title"]: m["status"] for m in _section("milestones")["milestones"]}

    assert status["Section 3 bridge complete"] == "notMet"
    assert status["Practical completion"] == "scheduled"
    assert status["Mobilisation"] == "met"


@pytest.mark.parametrize(
    ("due", "met", "as_of", "expected"),
    [
        ("2026-09-30", None, "2026-10-01", "notMet"),
        ("2026-09-30", None, "2026-09-30", "scheduled"),  # due today is not late yet
        ("2026-09-30", "2026-10-15", "2026-11-01", "met"),  # met late is still met
    ],
)
def test_milestone_status(due, met, as_of, expected):
    milestone = {"dueDate": due, "dateMet": met}

    assert milestone_status(milestone, date.fromisoformat(as_of)) == expected


def test_the_aide_memoire_carries_last_missions_promises():
    text = FILES["documents/aide-memoire-2026-05.md"].decode()

    assert "Start the Section 3 bridge works | Contractor | 2026-07-31 | Not started" in text
    assert "Fictional" in text


def test_the_progress_report_says_half_the_road_and_no_bridge():
    text = FILES["documents/progress-report-2026-09.md"].decode()

    assert "32 of 64 km" in text and "not started" in text


def test_the_same_data_gives_the_same_bytes():
    assert pack_files(DATA) == FILES
    assert all(data.endswith(b"\n") for data in FILES.values())


def test_the_whole_pack_fits_the_pack_format():
    manifest = build_manifest(
        org_id="kandor-works",
        mission_id=DATA["mission"]["id"],
        version=1,
        files=FILES,
        created_at=datetime(2026, 11, 3, tzinfo=UTC),
        valid_for=timedelta(days=30),
        min_app_version="0.5",
        key_id="0123456789abcdef",
    )

    assert len(json.loads(manifest)["files"]) == 12


def test_cancelled_money_is_not_counted_as_still_to_pay():
    data = json.loads(json.dumps(DATA))
    data["pack"]["supervision"]["financing"]["cancelled"] = 1_000_000

    financing = json.loads(pack_files(data)["sections/financing.json"])

    assert financing["undisbursed"] == 12_000_000 - 1_000_000 - 9_150_000


@pytest.mark.parametrize("path", sorted(p for p in FILES if p.endswith(".json")))
def test_every_json_file_keeps_its_keys_in_order(path):
    def keys_sorted(node: object) -> bool:
        if isinstance(node, dict):
            return list(node) == sorted(node) and all(keys_sorted(v) for v in node.values())
        if isinstance(node, list):
            return all(keys_sorted(v) for v in node)
        return True

    assert keys_sorted(json.loads(FILES[path]))


def test_both_documents_say_they_are_fictional():
    for path in ("documents/aide-memoire-2026-05.md", "documents/progress-report-2026-09.md"):
        assert "Kandor is not a real country" in FILES[path].decode()
