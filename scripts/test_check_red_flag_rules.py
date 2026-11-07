"""The red-flag rules file (docs/rules/red-flag-rules.json) and the table in ADR 0010 must name the
same rules with the same sources (#134): the decision and the data the phone runs cannot drift."""

import json
from pathlib import Path

import pytest
from check_red_flag_rules import adr_rules, main, problems

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
OPEN = "Open Contracting red flags guide (2024)"
AHEAD = "Custom (payment ahead of progress)"
ADR = """## Decision
| Rule id | Source | Raises a flag when |
|---|---|---|
| R068 | Open Contracting red flags guide (2024) | Sum of payments exceeds the contract value |
| MC-01 | Custom (payment ahead of progress) | Financial minus physical progress above 20 points |

Each flag stores: rule id.
"""


def rules_file(*rules: tuple[str, str]) -> dict:
    return {"version": 1, "rules": [{"id": rid, "source": source} for rid, source in rules]}


def test_the_adr_table_is_read_as_ids_and_sources_in_order():
    assert adr_rules(ADR) == [
        ("R068", OPEN),
        ("MC-01", AHEAD),
    ]


def test_the_same_rules_and_sources_pass():
    file = rules_file(("R068", OPEN), ("MC-01", AHEAD))

    assert problems(ADR, file) == []


def test_a_rule_missing_from_the_file_is_named():
    file = rules_file(("R068", OPEN))

    assert problems(ADR, file) == ["MC-01 is in ADR 0010 but not in the rules file"]


def test_a_rule_only_in_the_file_is_named():
    file = rules_file(
        ("R068", OPEN),
        ("MC-01", AHEAD),
        ("MC-09", "Custom"),
    )

    assert problems(ADR, file) == ["MC-09 is in the rules file but not in ADR 0010"]


def test_a_different_source_is_named():
    file = rules_file(("R068", "Open Contracting (2019)"), ("MC-01", AHEAD))

    assert problems(ADR, file) == [
        f"R068 source differs: ADR 0010 says '{OPEN}', the file says 'Open Contracting (2019)'"
    ]


def test_a_different_order_is_named():
    file = rules_file(("MC-01", AHEAD), ("R068", OPEN))

    assert problems(ADR, file) == ["the rules are in a different order than in ADR 0010"]


def test_the_real_repo_passes(monkeypatch):
    adr = (ROOT / "docs/adr/0010-red-flag-rule-engine.md").read_text(encoding="utf-8")
    file = json.loads((ROOT / "docs/rules/red-flag-rules.json").read_text(encoding="utf-8"))

    assert problems(adr, file) == []
    monkeypatch.chdir(ROOT)
    assert main() == 0
