"""Fail when an app screen uses a raw color instead of a theme role (#87).

Every color must come from ios/MissionCopilot/Platform/Theme, where the contrast test checks it in
light, dark and increased contrast. A raw color (.red, Color.blue, Color(red:...), .secondary) skips
that test and can be unreadable outdoors.

Usage: python scripts/check_theme_colors.py   (checks files tracked by git)
When it fires: use Color(.role) with a role from Palette.swift; add a role there if none fits.
"""

import re
import subprocess
import sys
from pathlib import Path

NAMES = (
    "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|black|white"
    "|primary|secondary|tertiary|quaternary|accentColor"
)
RAW_INIT = re.compile(
    r"\b(Color|UIColor)\((red|white|hue|uiColor|\.system)|#colorLiteral|\bColor\.(" + NAMES + r")\b"
)
MODIFIERS = "foregroundStyle|foregroundColor|tint|background|fill|stroke|border|accentColor"
MODIFIER = re.compile(r"\.(" + MODIFIERS + r")\(")
NAMED = re.compile(r"(?<![\w)\]])\.(" + NAMES + r")\b")


def in_scope(path: Path) -> bool:
    posix = "/" + path.as_posix()
    in_app = "/ios/MissionCopilot/" in posix
    return path.suffix == ".swift" and in_app and "/Platform/Theme/" not in posix


def is_raw(line: str) -> bool:
    if line.strip().startswith("//"):
        return False
    return bool(RAW_INIT.search(line) or (MODIFIER.search(line) and NAMED.search(line)))


def find_raw_colors(paths: list[Path]) -> list[tuple[Path, int, str]]:
    found = []
    for path in filter(in_scope, paths):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if is_raw(line):
                found.append((path, number, line.strip()))
    return found


def tracked_files() -> list[Path]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)  # noqa: S607
    return [Path(line) for line in out.stdout.splitlines() if line]


def main() -> int:
    found = find_raw_colors(tracked_files())
    for path, number, line in found:
        print(f"RAW COLOR: {path}:{number}: {line}  (use Color(.role) from the theme)")
    if not found:
        print("OK: every app color comes from the theme")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
