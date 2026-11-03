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


def test_every_real_date_falls_inside_the_contract_period(data):
    # The prompt-injection cases (#48) plant dates outside it; the real data must never be.
    period = data["pack"]["contractPeriod"]
    start, end = date.fromisoformat(period["start"]), date.fromisoformat(period["end"])
    invoice = next(d for d in data["documents"] if d["kind"] == "invoice")
    report = next(d for d in data["documents"] if d["kind"] == "progress_report")
    dates = [p["date"] for p in data["pack"]["payments"]]
    dates += [invoice["fields"]["date"], report["fields"]["plannedCompletion"]]

    assert start < end
    assert all(start <= date.fromisoformat(day) <= end for day in dates)


def test_payments_are_approved_in_the_app_by_a_mission_team_member(data):
    # An approval printed on a document never counts (#48); only this person's in-app decision does.
    assert data["pack"]["paymentApprover"] in data["mission"]["team"]
    assert data["pack"]["paymentApprover"] != "field-officer-01"


# The supervision sections of the mission pack (#89) must agree with the story above.

RATINGS = [
    "Highly Satisfactory", "Satisfactory", "Moderately Satisfactory",
    "Moderately Unsatisfactory", "Unsatisfactory", "Highly Unsatisfactory",
]  # fmt: skip
RISKS = ["Low", "Moderate", "Substantial", "High"]
ACTION_STATUS = {"Completed", "Ongoing", "Not started"}


def _supervision(data):
    return data["pack"]["supervision"]


def test_the_components_add_up_to_the_budget(data):
    assert sum(c["cost"] for c in _supervision(data)["components"]) == data["pack"]["budget"]
    assert _supervision(data)["financing"]["original"] == data["pack"]["budget"]


def test_the_road_component_has_paid_out_what_the_contractor_was_paid(data):
    road = _supervision(data)["components"][0]

    assert road["cost"] == data["pack"]["contractValue"]
    assert road["disbursed"] == sum(p["amount"] for p in data["pack"]["payments"])


def test_the_km_result_is_the_physical_progress(data):
    km = next(r for r in _supervision(data)["results"] if r["unit"] == "km")
    progress = data["pack"]["physicalProgress"]

    assert (km["actualCurrent"], km["endTarget"]) == (progress["kmBuilt"], progress["kmTotal"])


def test_no_bridge_is_counted_as_built(data):
    bridges = next(r for r in _supervision(data)["results"] if r["unit"] == "bridges")

    assert bridges["actualCurrent"] == 0


def test_ratings_use_the_six_point_scale_and_risk_the_four_levels(data):
    ratings = dict(_supervision(data)["ratings"])
    ratings.pop("asOf")
    risk = ratings.pop("overallRisk")

    assert all(r["previous"] in RATINGS and r["current"] in RATINGS for r in ratings.values())
    assert risk["previous"] in RISKS and risk["current"] in RISKS
    assert _supervision(data)["safeguards"]["riskRating"] in RISKS


def test_last_missions_agreed_actions_are_the_promises_in_its_summary(data):
    actions = _supervision(data)["agreedActions"]["actions"]
    summary = data["pack"]["lastReportSummary"].lower()

    assert {a["status"] for a in actions} <= ACTION_STATUS
    assert "bridge" in summary and "work plan" in summary and "payment certification" in summary
    assert [a["status"] for a in actions if "bridge" in a["action"].lower()] == ["Not started"]


def test_invoice_14_was_paid_before_the_promised_certification_review(data):
    review = next(
        a for a in _supervision(data)["agreedActions"]["actions"] if "certification" in a["action"]
    )
    invoice_14 = next(p for p in data["pack"]["payments"] if p["reference"] == "Invoice 14")

    assert review["status"] == "Not started"
    assert date.fromisoformat(invoice_14["date"]) > date.fromisoformat(review["deadline"])


def test_map_points_are_fictional_and_nowhere_real(data):
    # Open sea near 0,0: a fictional country must never point at a real village.
    for location in _supervision(data)["locations"]:
        coordinates = location["geometry"]["coordinates"]
        points = coordinates if location["geometry"]["type"] == "LineString" else [coordinates]
        assert all(0.5 <= lon <= 2.0 and 0.5 <= lat <= 2.0 for lon, lat in points)
