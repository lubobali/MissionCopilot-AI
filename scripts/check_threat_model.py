"""Fail when the threat model claims more than the repo shows.

Every threat row (T01, P01, ...) needs a known status. "built" must name a file that exists;
"spike" must name its proof and the phase or issue that rebuilds it in the app; "planned" must
name a phase or issue; "accepted" must give a reason. A finished phase is no plan: raise
LAST_FINISHED_PHASE in each iteration review, and every row still pointing at it fails.

Usage: python scripts/check_threat_model.py   (checks docs/threat-model.md)
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path

MODEL = Path("docs/threat-model.md")
ROW = re.compile(r"^\|\s*([TP]\d{2})\s*\|")
PHASE = re.compile(r"Phase (\d+)")
ISSUE = re.compile(r"#\d+")
LAST_FINISHED_PHASE = 4
PATH = re.compile(r"`([^`\s]+)`")


@dataclass(frozen=True)
class Row:
    id: str
    cells: list[str]


def parse_rows(text: str) -> list[Row]:
    rows = []
    for line in text.splitlines():
        match = ROW.match(line)
        if match:
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            rows.append(Row(match.group(1), cells))
    return rows


def problems(rows: list[Row], root: Path) -> list[str]:
    if not rows:
        return ["no threat rows found"]
    found, seen = [], set()
    for row in rows:
        if row.id in seen:
            found.append(f"{row.id}: duplicate id")
            continue
        seen.add(row.id)
        if len(row.cells) != 6:
            found.append(f"{row.id}: expected 6 cells, found {len(row.cells)}")
            continue
        found.extend(check_claim(row.id, row.cells[4], row.cells[5], root))
    return found


def _is_repo_path(text: str) -> bool:
    """`deploy/RUNBOOK.md` is a file in the repo; `/v1/health` is a route, `X-App-Build` a name."""
    return "/" in text and not text.startswith("/")


def check_claim(
    row_id: str,
    status: str,
    where: str,
    root: Path,
    reasoned: frozenset[str] = frozenset({"accepted"}),
) -> list[str]:
    """One claim's rules, shared with the MASVS matrix: built and spike name a real file, spike and
    planned name a phase or issue, and a status that needs a reason (accepted) gives one."""
    if status not in {"built", "spike", "planned"} | reasoned:
        return [f"{row_id}: unknown status '{status}'"]
    named = PATH.findall(where)
    has_file = any((root / path).exists() for path in named)
    phases = [int(number) for number in PHASE.findall(where)]
    open_phase = any(number > LAST_FINISHED_PHASE for number in phases)
    has_phase = open_phase or bool(ISSUE.search(where))
    if status == "built" and not has_file:
        return [f"{row_id}: built, but no existing file is named (got: {where})"]
    if status == "spike" and not has_file:
        return [f"{row_id}: spike, but its proof file does not exist (got: {where})"]
    missing = [path for path in named if _is_repo_path(path) and not (root / path).exists()]
    if missing:  # every named file, not just one: a renamed test must not hide behind another
        return [f"{row_id}: names a file that does not exist: {', '.join(missing)}"]
    if status in {"spike", "planned"} and phases and not has_phase:
        finished = f"Phase {max(phases)} is finished"
        return [f"{row_id}: {status}, but {finished}; name a later phase or an issue"]
    if status == "spike" and not has_phase:
        return [f"{row_id}: spike, but no phase or issue rebuilds it in the app"]
    if status == "planned" and not has_phase:
        return [f"{row_id}: planned, but no phase or issue"]
    if status in reasoned and len(where) < 12:
        return [f"{row_id}: {status}, but no reason given"]
    return []


def main() -> int:
    found = problems(parse_rows(MODEL.read_text(encoding="utf-8")), Path("."))
    for problem in found:
        print(f"THREAT MODEL: {problem}")
    if not found:
        print("OK: every threat has a status, and every claim points at a file, phase or issue")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
