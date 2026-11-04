"""Fail when the Mac, CI, the image and the server could run different uv versions.

The one pin is backend/pyproject.toml [tool.uv] required-version = "==X.Y.Z" (uv itself refuses to
run at another version). Every astral-sh/setup-uv step must read that file (version-file), and a
Dockerfile that copies uv from ghcr.io/astral-sh/uv must use the same version.

Usage: python scripts/check_uv_pin.py   (from the repo root)
"""

import re
import sys
from pathlib import Path

PYPROJECT = Path("backend/pyproject.toml")
WORKFLOWS = Path(".github/workflows")
PIN = re.compile(r'^required-version\s*=\s*"==(\d+\.\d+\.\d+)"\s*$', re.MULTILINE)
SETUP_UV = re.compile(r"^(\s*)-?\s*uses:\s*astral-sh/setup-uv@")
READS_PIN = re.compile(r"^\s*version-file:\s*backend/pyproject\.toml\s*$")
UV_IMAGE = re.compile(r"ghcr\.io/astral-sh/uv:(\d+\.\d+\.\d+)")


def pinned_version(pyproject: str) -> str | None:
    found = PIN.search(pyproject)
    return found.group(1) if found else None


def _step_reads_pin(lines: list[str], start: int, indent: int) -> bool:
    """The lines after a `uses:` that still belong to its step (indented deeper than its dash)."""
    for line in lines[start + 1 :]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            return False
        if READS_PIN.match(line):
            return True
    return False


def _workflow_problems(name: str, text: str) -> list[str]:
    lines = text.splitlines()
    found = []
    for number, line in enumerate(lines):
        match = SETUP_UV.match(line)
        if match and not _step_reads_pin(lines, number, len(match.group(1))):
            found.append(
                f"{name}: setup-uv on line {number + 1} does not read backend/pyproject.toml "
                "(version-file)"
            )
    return found


def problems(pyproject: str, workflows: dict[str, str], dockerfiles: dict[str, str]) -> list[str]:
    version = pinned_version(pyproject)
    if version is None:
        return [f'{PYPROJECT}: no exact pin; add [tool.uv] required-version = "==X.Y.Z"']
    found = []
    for name, text in sorted(workflows.items()):
        found += _workflow_problems(name, text)
    for name, text in sorted(dockerfiles.items()):
        found += [
            f"{name}: uv image {other}, but the pin is {version}"
            for other in UV_IMAGE.findall(text)
            if other != version
        ]
    return found


def main() -> int:
    workflows = {str(p): p.read_text(encoding="utf-8") for p in sorted(WORKFLOWS.glob("*.yml"))}
    dockerfiles = {
        str(p): p.read_text(encoding="utf-8")
        for p in sorted(Path(".").rglob("Dockerfile*"))
        if ".venv" not in p.parts and "private" not in p.parts
    }
    found = problems(PYPROJECT.read_text(encoding="utf-8"), workflows, dockerfiles)
    for problem in found:
        print(f"UV PIN: {problem}")
    if not found:
        print("OK: CI and images use the uv version pinned in backend/pyproject.toml")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
