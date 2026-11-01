"""The prompt-injection set (#48) must be a fair test: every attack really carries its payload, the
attacker's value is never the true one, clean controls are untouched copies, and the answer key says
what each attack wants so code (not a person) can score it. These tests check the set itself."""

import json
from datetime import date
from pathlib import Path

import pytest
from make_debrief_audio import debrief
from make_injection_set import FAMILIES, HIDDEN_STYLES, answer_key, cases
from make_scan_documents import invoice_page, progress_report_page

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
DATA = json.loads((ROOT / "docs" / "demo" / "kandor-rural-roads.json").read_text(encoding="utf-8"))
CASES = cases(DATA)
ATTACKS = [c for c in CASES if c.family != "clean"]


def content(case) -> str:
    """Everything the case puts in front of the phone, visible or not."""
    if case.page is None:
        return case.text
    rows = [" ".join(row) for row in case.page.table.rows]
    return "\n".join([*case.page.lines, *rows, *case.hidden])


def test_there_are_at_least_30_attacks_and_a_clean_control_per_source():
    assert len(ATTACKS) >= 30
    assert {c.base for c in CASES if c.family == "clean"} == {
        "invoice-14",
        "progress-report-2026-09",
        "debrief-en",
    }
    assert len({c.id for c in CASES}) == len(CASES)


def test_every_family_is_covered():
    assert {c.family for c in ATTACKS} == set(FAMILIES)


def test_every_attack_carries_its_payload():
    for case in ATTACKS:
        assert case.payload in content(case), case.id


def test_the_attackers_value_is_never_the_true_value():
    for case in ATTACKS:
        assert case.target.attacker != case.target.truth, case.id


def test_clean_controls_are_exact_copies_of_the_real_documents():
    clean = {c.base: c for c in CASES if c.family == "clean"}

    assert clean["invoice-14"].page == invoice_page(DATA)
    assert clean["progress-report-2026-09"].page == progress_report_page(DATA)
    assert clean["debrief-en"].text == debrief(DATA, "en").text


def test_hidden_text_is_only_hidden():
    hidden = [c for c in ATTACKS if c.family == "hidden_text"]

    assert {c.style for c in hidden} == set(HIDDEN_STYLES)
    for case in hidden:
        assert case.payload in case.hidden
        assert case.page == invoice_page(DATA), case.id  # the visible page is untouched


def test_the_changed_table_row_no_longer_adds_up_and_the_consistent_forgery_does():
    def rows_total(case) -> int:
        return sum(int(row[2].replace(",", "")) for row in case.page.table.rows)

    by_id = {c.id: c for c in CASES}
    real_paid = sum(p["amount"] for p in DATA["pack"]["payments"])

    assert rows_total(by_id["F3"]) != real_paid  # the printed paid to date still says 8,500,000
    assert rows_total(by_id["F4"]) == by_id["F4"].target.attacker != real_paid


def test_date_attacks_fall_outside_the_contract_period():
    period = DATA["pack"]["contractPeriod"]
    start, end = date.fromisoformat(period["start"]), date.fromisoformat(period["end"])
    dates = [c for c in ATTACKS if c.family == "date_outside_contract" and c.id != "D3"]

    assert len(dates) >= 3
    for case in dates:
        assert not start <= date.fromisoformat(case.target.attacker) <= end, case.id


def test_spoken_attacks_use_a_stock_system_voice_and_keep_the_real_debrief():
    spoken = [c for c in ATTACKS if c.channel == "speech"]
    real = debrief(DATA, "en").text.removesuffix(" End of debrief.")

    assert len(spoken) >= 5
    for case in spoken:
        assert case.voice == "Samantha"  # a built-in macOS voice, never a clone of a real person
        assert case.text.startswith(real), case.id


def test_the_oversized_input_is_far_beyond_one_page():
    oversized = [c for c in ATTACKS if c.family == "oversized_input"]

    assert len(oversized) == 1
    assert len(oversized[0].text) > 100_000


def test_every_scan_still_says_it_is_fictional():
    for case in CASES:
        if case.page is not None:
            assert any("Fictional demo document" in line for line in case.page.footer), case.id


def test_the_answer_key_lists_what_each_case_wants_without_the_huge_text():
    key = answer_key(DATA)
    first = key["cases"][0]

    assert {
        "id",
        "family",
        "channel",
        "base",
        "file",
        "payload",
        "style",
        "target",
        "defense",
    } <= set(first)
    assert len(json.dumps(key)) < 100_000
    assert key["contractPeriod"] == DATA["pack"]["contractPeriod"]


def test_committed_answer_key_matches_the_dataset():
    # Catches a dataset edit without rebuilding: run scripts/make_injection_set.py, then commit.
    committed = ROOT / "docs" / "demo" / "injection" / "answer-key.json"
    assert json.loads(committed.read_text(encoding="utf-8")) == answer_key(DATA)
