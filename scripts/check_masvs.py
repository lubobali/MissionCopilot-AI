"""Fail when the OWASP MASVS v2.1 matrix claims more than the repo shows (story #49).

All 24 controls must appear once, with the official wording (pinned below from the MASVS v2.1.0
release, January 2024), and each status follows the threat model's rules: built and spike name a
file that exists, spike and planned name a phase or issue, accepted and not applicable give a
reason.

Usage: python scripts/check_masvs.py   (checks docs/masvs.md)
"""

import re
import sys
from pathlib import Path

from check_threat_model import Row, check_claim

MATRIX = Path("docs/masvs.md")
ROW = re.compile(r"^\|\s*(MASVS-[A-Z]+-\d)\s*\|")
REASONED = frozenset({"accepted", "not applicable"})
OFFICIAL = {
    "MASVS-STORAGE-1": "The app securely stores sensitive data.",
    "MASVS-STORAGE-2": "The app prevents leakage of sensitive data.",
    "MASVS-CRYPTO-1": "The app employs current strong cryptography and uses it according to "
    "industry best practices.",
    "MASVS-CRYPTO-2": "The app performs key management according to industry best practices.",
    "MASVS-AUTH-1": "The app uses secure authentication and authorization protocols and follows "
    "the relevant best practices.",
    "MASVS-AUTH-2": "The app performs local authentication securely according to the platform best "
    "practices.",
    "MASVS-AUTH-3": "The app secures sensitive operations with additional authentication.",
    "MASVS-NETWORK-1": "The app secures all network traffic according to the current best "
    "practices.",
    "MASVS-NETWORK-2": "The app performs identity pinning for all remote endpoints under the "
    "developer's control.",
    "MASVS-PLATFORM-1": "The app uses IPC mechanisms securely.",
    "MASVS-PLATFORM-2": "The app uses WebViews securely.",
    "MASVS-PLATFORM-3": "The app uses the user interface securely.",
    "MASVS-CODE-1": "The app requires an up-to-date platform version.",
    "MASVS-CODE-2": "The app has a mechanism for enforcing app updates.",
    "MASVS-CODE-3": "The app only uses software components without known vulnerabilities.",
    "MASVS-CODE-4": "The app validates and sanitizes all untrusted inputs.",
    "MASVS-RESILIENCE-1": "The app validates the integrity of the platform.",
    "MASVS-RESILIENCE-2": "The app implements anti-tampering mechanisms.",
    "MASVS-RESILIENCE-3": "The app implements anti-static analysis mechanisms.",
    "MASVS-RESILIENCE-4": "The app implements anti-dynamic analysis techniques.",
    "MASVS-PRIVACY-1": "The app minimizes access to sensitive data and resources.",
    "MASVS-PRIVACY-2": "The app prevents identification of the user.",
    "MASVS-PRIVACY-3": "The app is transparent about data collection and usage.",
    "MASVS-PRIVACY-4": "The app offers user control over their data.",
}


def parse_rows(text: str) -> list[Row]:
    rows = []
    for line in text.splitlines():
        match = ROW.match(line)
        if match:
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            rows.append(Row(match.group(1), cells))
    return rows


def problems(rows: list[Row], root: Path) -> list[str]:
    found, seen = [], set()
    for row in rows:
        if row.id in seen:
            found.append(f"{row.id}: duplicate")
            continue
        seen.add(row.id)
        if len(row.cells) != 4:
            found.append(f"{row.id}: expected 4 cells, found {len(row.cells)}")
            continue
        if row.cells[1] != OFFICIAL.get(row.id):
            found.append(f"{row.id}: not the official wording")
            continue
        found.extend(check_claim(row.id, row.cells[2], row.cells[3], root, REASONED))
    found += [f"{cid}: missing" for cid in OFFICIAL if cid not in seen]
    return found


def main() -> int:
    found = problems(parse_rows(MATRIX.read_text(encoding="utf-8")), Path("."))
    for problem in found:
        print(f"MASVS: {problem}")
    if not found:
        print("OK: all 24 MASVS controls, official wording, every claim backed")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
