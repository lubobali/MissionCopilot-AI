"""Fail when an architecture decision record is missing a required section.

Usage: python scripts/check_adrs.py   (checks docs/adr/NNNN-*.md, except the template)
"""

import re
import sys
from pathlib import Path

REQUIRED = ["Context", "Options", "Decision", "Why", "Consequences", "Revisit when"]
ADR_DIR = Path("docs/adr")


def missing_sections(text: str) -> list[str]:
    headings = set(re.findall(r"^## (.+?)\s*$", text, flags=re.MULTILINE))
    return [name for name in REQUIRED if name not in headings]


def main() -> int:
    failed = False
    for path in sorted(ADR_DIR.glob("[0-9][0-9][0-9][0-9]-*.md")):
        if path.name.startswith("0000-"):
            continue
        missing = missing_sections(path.read_text(encoding="utf-8"))
        if missing:
            failed = True
            print(f"INCOMPLETE ADR: {path} is missing: {', '.join(missing)}")
    if not failed:
        print("OK: every ADR has all required sections")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
