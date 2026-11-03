"""Fail when an app screen uses a raw color or a fixed text size instead of the theme (#87).

Every color must come from ios/MissionCopilot/Platform/Theme, where the contrast test checks it in
light, dark and increased contrast. A raw color (.red, Color.blue, Color(red:...), .secondary) skips
that test and can be unreadable outdoors. A fixed size (.system(size: 17)) ignores the person's text
size setting; screens use text styles (.headline, .body) and the theme's scaled sizes.

Usage: python scripts/check_theme.py   (checks git files)
When it fires: use Color(.role) with a role from Palette.swift (add a role there if none fits),
and a text style or a theme view such as HeroIcon for sizes.
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
FIXED_SIZE = re.compile(r"\.system\(size:|\.custom\(")


def in_scope(path: Path) -> bool:
    posix = "/" + path.as_posix()
    in_app = "/ios/MissionCopilot/" in posix
    return path.suffix == ".swift" and in_app and "/Platform/Theme/" not in posix


def is_raw(line: str) -> bool:
    if line.strip().startswith("//"):
        return False
    return bool(RAW_INIT.search(line) or (MODIFIER.search(line) and NAMED.search(line)))


def is_fixed_size(line: str) -> bool:
    if line.strip().startswith("//"):
        return False
    return bool(FIXED_SIZE.search(line)) and "relativeTo:" not in line


def find(paths: list[Path], rule) -> list[tuple[Path, int, str]]:
    found = []
    for path in filter(in_scope, paths):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if rule(line):
                found.append((path, number, line.strip()))
    return found


def find_raw_colors(paths: list[Path]) -> list[tuple[Path, int, str]]:
    return find(paths, is_raw)


def find_fixed_sizes(paths: list[Path]) -> list[tuple[Path, int, str]]:
    return find(paths, is_fixed_size)


def tracked_files() -> list[Path]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)  # noqa: S607
    return [Path(line) for line in out.stdout.splitlines() if line]


def main() -> int:
    files = tracked_files()
    colors, sizes = find_raw_colors(files), find_fixed_sizes(files)
    for path, number, line in colors:
        print(f"RAW COLOR: {path}:{number}: {line}  (use Color(.role) from the theme)")
    for path, number, line in sizes:
        print(f"FIXED SIZE: {path}:{number}: {line}  (use a text style or a theme view)")
    if not colors and not sizes:
        print("OK: every app color and text size comes from the theme")
    return 1 if colors or sizes else 0


if __name__ == "__main__":
    sys.exit(main())
