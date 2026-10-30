import pytest
from check_adrs import missing_sections

pytestmark = pytest.mark.unit

FULL = "# ADR\n## Context\n## Options\n## Decision\n## Why\n## Consequences\n## Revisit when\n"


def test_complete_adr_has_nothing_missing():
    assert missing_sections(FULL) == []


def test_missing_sections_are_listed_in_order():
    text = "# ADR\n## Context\n## Decision\n## Why\n"

    assert missing_sections(text) == ["Options", "Consequences", "Revisit when"]


def test_heading_must_start_the_line():
    text = FULL.replace("## Why\n", "see the ## Why part\n")

    assert missing_sections(text) == ["Why"]
