"""The one-page data handling sheet (docs/data-handling.md) must cover every item in the data
map (docs/data-classification.md) and answer every question for each: where it lives, how long,
how it is encrypted, who can see it, where it is hosted and how it ends. These tests feed the guard
small files."""

from pathlib import Path

import pytest
from check_data_handling import COLUMNS, problems, table_rows

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
MAP = """## 3. Data map

| Data item | Owner | Label |
|---|---|---|
| Voice audio | Officer | OUO |
| Mission key | Device | Secret |

## 4. Next
"""
HEADER = "| " + " | ".join(COLUMNS) + " |\n|" + "---|" * len(COLUMNS) + "\n"


def sheet(*rows: str) -> str:
    return "# Data handling\n\n" + HEADER + "".join(rows)


FULL = "| {} | Phone | 14 days | DK + MK | Officer | Phone only | Shredded |\n"


def test_a_complete_sheet_passes():
    assert problems(MAP, sheet(FULL.format("Voice audio"), FULL.format("Mission key"))) == []


def test_an_item_missing_from_the_sheet_is_reported():
    assert problems(MAP, sheet(FULL.format("Voice audio"))) == [
        "Mission key: in the data map but not in the sheet"
    ]


def test_an_empty_cell_is_reported():
    gap = "| Mission key | Keychain |  | SE | Nobody | Phone only | Shredded |\n"

    assert problems(MAP, sheet(FULL.format("Voice audio"), gap)) == ["Mission key: no How long"]


def test_a_row_with_too_few_cells_is_reported():
    short = "| Mission key | Keychain | Until shred |\n"

    assert problems(MAP, sheet(FULL.format("Voice audio"), short)) == [
        "Mission key: no Encryption",
        "Mission key: no Who can see it",
        "Mission key: no Hosted",
        "Mission key: no How it ends",
    ]


def test_a_missing_column_is_reported():
    short = "# Data handling\n\n| Data | Where it lives |\n|---|---|\n| Voice audio | Phone |\n"

    assert problems(MAP, short)[0].startswith("sheet columns must be")


def test_only_the_data_map_table_counts():
    # Tables in other sections of data-classification.md are not data items.
    other = MAP + "\n| Label | Meaning |\n|---|---|\n| OUO | Official use |\n"

    assert problems(other, sheet(FULL.format("Voice audio"), FULL.format("Mission key"))) == []


def test_header_and_divider_rows_are_not_items():
    assert [row[0] for row in table_rows(sheet(FULL.format("Voice audio")))] == ["Voice audio"]


def test_no_data_map_is_itself_a_problem():
    assert problems("# Nothing here\n", sheet()) == ["no data map found"]


def test_the_repo_sheet_covers_the_repo_data_map():
    data_map = (ROOT / "docs" / "data-classification.md").read_text(encoding="utf-8")
    handling = (ROOT / "docs" / "data-handling.md").read_text(encoding="utf-8")

    assert problems(data_map, handling) == []
