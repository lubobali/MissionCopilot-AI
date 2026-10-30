"""Fail when a code file grows past the line limit, so no file turns into a monolith.

Usage: python scripts/check_file_size.py [--limit N]   (checks files tracked by git)
When it fires: split the file into smaller focused modules. Do not raise the limit.
"""

import argparse
import subprocess
import sys
from pathlib import Path

CODE_SUFFIXES = {".py", ".swift", ".ts", ".tsx"}
DEFAULT_LIMIT = 300


def find_oversized(paths: list[Path], limit: int = DEFAULT_LIMIT) -> list[tuple[Path, int]]:
    oversized = []
    for path in paths:
        if path.suffix not in CODE_SUFFIXES:
            continue
        with path.open(encoding="utf-8") as f:
            count = sum(1 for _ in f)
        if count > limit:
            oversized.append((path, count))
    return oversized


def tracked_files() -> list[Path]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)  # noqa: S607
    return [Path(line) for line in out.stdout.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    args = parser.parse_args()
    oversized = find_oversized(tracked_files(), args.limit)
    for path, count in oversized:
        print(f"TOO BIG: {path} has {count} lines (limit {args.limit}). Split it.")
    if not oversized:
        print(f"OK: no code file over {args.limit} lines")
    return 1 if oversized else 0


if __name__ == "__main__":
    sys.exit(main())
