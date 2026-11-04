"""The demo road checklist (#93): its source is an admin's .xlsx form (docs/demo/forms), and the
demo dataset carries exactly what the backend's converter makes of it, so the two cannot drift. It
uses every type and rule the app reads, in English and French."""

import json
from pathlib import Path

import pytest

from missioncopilot_backend.checklist_xlsx import from_xlsx

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "demo" / "forms" / "road-checklist.xlsx"
DATASET = json.loads((ROOT / "docs/demo/kandor-rural-roads.json").read_text(encoding="utf-8"))
CHECKLIST = DATASET["pack"]["checklist"]


def test_the_dataset_carries_the_xlsx_form_converted_with_nothing_dropped():
    form, dropped = from_xlsx(SOURCE)

    assert form == {key: CHECKLIST[key] for key in ("settings", "survey", "choices")}
    assert dropped == []


def test_it_uses_every_type_and_rule_the_app_reads():
    survey = CHECKLIST["survey"]
    types = {row["type"].split()[0] for row in survey}
    rules = " ".join(row.get("constraint", "") + row.get("relevant", "") for row in survey)

    assert types == {
        "select_one",
        "select_multiple",
        "decimal",
        "integer",
        "text",
        "date",
        "note",
        "geopoint",
        "image",
        "begin_group",
        "end_group",
    }
    for used in ("${bridge_started}", "selected(", "count-selected(", "today()", "regex(", "not("):
        assert used in rules
    assert all("label::French (fr)" in row for row in survey if row["type"] != "end_group")
    assert all("label::French (fr)" in choice for choice in CHECKLIST["choices"])
