"""Fail when the data handling sheet stops answering for every piece of data (story #49).

Every item in the data map (docs/data-classification.md, section "Data map") must be a row in
docs/data-handling.md, and every cell of that row must be filled: where it lives, how long, how it
is encrypted, who can see it, where it is hosted and how it ends.

Usage: python scripts/check_data_handling.py
"""

import re
import sys
from pathlib import Path

DATA_MAP = Path("docs/data-classification.md")
SHEET = Path("docs/data-handling.md")
COLUMNS = [
    "Data",
    "Where it lives",
    "How long",
    "Encryption",
    "Who can see it",
    "Hosted",
    "How it ends",
]
DIVIDER = re.compile(r"^\|[\s|:-]+\|$")


def table_rows(text: str) -> list[list[str]]:
    """The cells of every table row after the first table's header, dividers left out."""
    rows = []
    for line in text.splitlines():
        if line.startswith("|") and not DIVIDER.match(line.strip()):
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
    return rows[1:]


def map_items(data_map: str) -> list[str]:
    match = re.search(r"^## \d+\. Data map\s*$(.*?)(?=^## |\Z)", data_map, re.M | re.S)
    if not match:
        return []
    return [row[0] for row in table_rows(match.group(1))]


def problems(data_map: str, sheet: str) -> list[str]:
    items = map_items(data_map)
    if not items:
        return ["no data map found"]
    header = next((line for line in sheet.splitlines() if line.startswith("|")), "")
    if [cell.strip() for cell in header.strip().strip("|").split("|")] != COLUMNS:
        return [f"sheet columns must be: {', '.join(COLUMNS)}"]
    rows = {row[0]: row for row in table_rows(sheet)}
    found = []
    for item in items:
        row = rows.get(item)
        if row is None:
            found.append(f"{item}: in the data map but not in the sheet")
            continue
        cells = row + [""] * (len(COLUMNS) - len(row))
        found += [
            f"{item}: no {name}" for name, cell in zip(COLUMNS, cells, strict=False) if not cell
        ]
    return found


def main() -> int:
    found = problems(DATA_MAP.read_text(encoding="utf-8"), SHEET.read_text(encoding="utf-8"))
    for problem in found:
        print(f"DATA HANDLING: {problem}")
    if not found:
        print("OK: every item in the data map has a full row in the data handling sheet")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
