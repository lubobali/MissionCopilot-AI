"""The scan test documents must say exactly what the demo dataset says, and so must the answer key.
If the dataset changes, these fail until the documents are rebuilt."""

import json
from pathlib import Path

import pytest
from make_scan_documents import answer_key, invoice_page, progress_report_page, spoken_date

pytestmark = pytest.mark.unit

DATA = json.loads(
    (Path(__file__).resolve().parents[1] / "docs" / "demo" / "kandor-rural-roads.json").read_text(
        encoding="utf-8"
    )
)


def test_dates_are_printed_the_way_people_write_them():
    assert spoken_date("2026-10-12") == "12 October 2026"
    assert spoken_date("2025-02-15", short=True) == "15 Feb 2025"


def test_invoice_shows_the_facts_in_print_form():
    page = invoice_page(DATA)
    text = "\n".join(page.lines)

    assert "Invoice No. 14" in text
    assert "12 October 2026" in text
    assert "USD 480,000" in text
    assert "USD 10,000,000" in text
    assert "USD 8,500,000" in text


def test_invoice_table_lists_every_payment_and_adds_up_to_paid_to_date():
    table = invoice_page(DATA).table

    assert table.headers == ["Date", "Reference", "Amount (USD)"]
    assert len(table.rows) == len(DATA["pack"]["payments"])
    assert table.rows[0] == ["15 Feb 2025", "Advance payment", "1,000,000"]
    assert sum(int(row[2].replace(",", "")) for row in table.rows) == 8_500_000


def test_progress_report_shows_km_and_bridge_status():
    text = "\n".join(progress_report_page(DATA).lines)

    assert "32 of 64 km" in text
    assert "Section 3 bridge: not started" in text


def test_milestone_table_keeps_unmet_dates_as_empty_cells():
    table = progress_report_page(DATA).table

    assert table.headers == ["Milestone", "Due", "Met"]
    assert table.rows[2] == ["Section 3 bridge complete", "30 Sep 2026", ""]


def test_answer_key_holds_the_eight_facts_and_both_tables():
    key = answer_key(DATA)

    assert key["facts"] == {
        "invoiceNumber": "14",
        "invoiceDate": "2026-10-12",
        "amountDue": 480000,
        "cumulativePaid": 8500000,
        "contractValue": 10000000,
        "kmCompleted": 32,
        "kmTotal": 64,
        "bridgeStatus": "not_started",
    }
    assert key["pages"]["invoice-14"]["lines"] == invoice_page(DATA).lines
    assert key["tables"]["invoice-14"]["rows"] == invoice_page(DATA).table.rows
    assert key["tables"]["progress-report-2026-09"]["rows"] == progress_report_page(DATA).table.rows


def test_every_page_says_it_is_fictional():
    for page in (invoice_page(DATA), progress_report_page(DATA)):
        assert any("Fictional demo document" in line for line in page.footer)


def test_committed_answer_key_matches_the_dataset():
    # Catches a dataset edit without rebuilding: run scripts/make_scan_documents.py, then commit.
    committed = Path(__file__).resolve().parents[1] / "docs" / "demo" / "scans" / "answer-key.json"
    assert json.loads(committed.read_text(encoding="utf-8")) == answer_key(DATA)
