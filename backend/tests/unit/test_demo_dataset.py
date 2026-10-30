"""The synthetic demo dataset (docs/demo/kandor-rural-roads.json) must keep telling the same story.
If someone edits the data and breaks a planted risk, these tests fail."""

import json
from datetime import date
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

DATA_PATH = Path(__file__).resolve().parents[3] / "docs" / "demo" / "kandor-rural-roads.json"
MC01_THRESHOLD_POINTS = 20


@pytest.fixture(scope="module")
def data():
    return json.loads(DATA_PATH.read_text(encoding="utf-8"))


def _financial_pct(data):
    paid = sum(p["amount"] for p in data["pack"]["payments"])
    return 100 * paid / data["pack"]["contractValue"]


def _physical_pct(data):
    progress = data["pack"]["physicalProgress"]
    return 100 * progress["kmBuilt"] / progress["kmTotal"]


def test_dataset_is_marked_fictional(data):
    assert data["fictional"] is True


def test_planted_financial_progress_is_85_percent(data):
    assert _financial_pct(data) == pytest.approx(85.0)


def test_planted_physical_progress_is_50_percent(data):
    assert _physical_pct(data) == pytest.approx(50.0)


def test_mc01_payment_ahead_of_progress_is_raised(data):
    assert _financial_pct(data) - _physical_pct(data) > MC01_THRESHOLD_POINTS


def test_r068_payments_do_not_exceed_contract_value(data):
    paid = sum(p["amount"] for p in data["pack"]["payments"])

    assert paid <= data["pack"]["contractValue"]


def test_r067_one_milestone_is_late_and_unmet(data):
    mission_start = date.fromisoformat(data["mission"]["startDate"])
    late = [
        m
        for m in data["pack"]["milestones"]
        if m["dateMet"] is None and date.fromisoformat(m["dueDate"]) < mission_start
    ]

    assert [m["title"] for m in late] == ["Section 3 bridge complete"]


def test_road_width_finding_is_about_30_percent_narrower(data):
    finding = data["fieldFindings"]["roadWidth"]
    narrower = 1 - finding["measuredM"] / finding["specM"]

    assert narrower == pytest.approx(0.30, abs=0.01)


def test_invoice_14_matches_the_last_payment(data):
    invoice = next(d for d in data["documents"] if d["kind"] == "invoice")

    assert invoice["fields"]["invoiceNumber"] == "14"
    assert invoice["fields"]["amount"] == data["pack"]["payments"][-1]["amount"]


def test_every_demo_moment_has_its_documents(data):
    kinds = {d["kind"] for d in data["documents"]}
    languages = {d["language"] for d in data["documents"]}

    assert {"invoice", "progress_report", "letter"} <= kinds
    assert "fr" in languages
    assert data["pack"]["checklist"]["survey"]
