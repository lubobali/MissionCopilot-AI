"""Fail when the red-flag rules file and ADR 0010's table disagree (#134).

The phone runs docs/rules/red-flag-rules.json; ADR 0010 is the decision. Both must name the same
rules, in the same order, with the same sources, so a rule can never be added, dropped or re-sourced
in one place only.

Usage: python scripts/check_red_flag_rules.py
"""

import json
import re
import sys
from pathlib import Path

ADR = Path("docs/adr/0010-red-flag-rule-engine.md")
RULES = Path("docs/rules/red-flag-rules.json")
ROW = re.compile(r"^\|\s*([A-Z]+-?\d+)\s*\|\s*([^|]+?)\s*\|", flags=re.MULTILINE)


def adr_rules(text: str) -> list[tuple[str, str]]:
    return ROW.findall(text)


def problems(adr_text: str, rules_file: dict) -> list[str]:
    adr = adr_rules(adr_text)
    file = [(rule["id"], rule["source"]) for rule in rules_file["rules"]]
    adr_sources, file_sources = dict(adr), dict(file)
    found = [
        f"{rid} is in ADR 0010 but not in the rules file"
        for rid, _ in adr
        if rid not in file_sources
    ]
    found += [
        f"{rid} is in the rules file but not in ADR 0010"
        for rid, _ in file
        if rid not in adr_sources
    ]
    found += [
        f"{rid} source differs: ADR 0010 says '{source}', the file says '{file_sources[rid]}'"
        for rid, source in adr
        if rid in file_sources and file_sources[rid] != source
    ]
    if not found and [rid for rid, _ in adr] != [rid for rid, _ in file]:
        found.append("the rules are in a different order than in ADR 0010")
    return found


def main() -> int:
    found = problems(ADR.read_text(encoding="utf-8"), json.loads(RULES.read_text(encoding="utf-8")))
    for problem in found:
        print(f"RED FLAG RULES: {problem}")
    if not found:
        print("OK: the rules file matches ADR 0010")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
