"""Whether the iOS lab tests must run for this CI event (#127, step 6.2.0.2).

Usage (a step in .github/workflows/ios.yml, output appended to $GITHUB_OUTPUT):
    python3 scripts/ios_ci_paths.py <event> <base sha> <head sha>

The labs take about 10 of the iOS job's 20 minutes and their code rarely changes, so a pull
request that changes only the app skips them. Everything else runs them: every push to main, the
weekly run, a manual run, any event this rule does not know, and any pull request whose changes
git cannot list. A pull request is compared as a whole with its base (base...head), never by its
last commit only. Our own git diff, no third-party action (tj-actions/changed-files was
compromised in 2025). Standard library only.
"""

from __future__ import annotations

import subprocess
import sys

# What the lab tests read or run: their code and test scripts, the demo scans and audio they score,
# this workflow, the simulator picker, and this rule itself.
LAB_INPUTS = (
    "ios/AILab/",
    "docs/demo/",
    ".github/workflows/ios.yml",
    "scripts/newest_iphone.py",
    "scripts/ios_ci_paths.py",
)


def labs_needed(event: str, changed: list[str] | None) -> bool:
    if event != "pull_request" or changed is None:
        return True
    return any(path.startswith(LAB_INPUTS) for path in changed)


def changed_files(base: str, head: str) -> list[str] | None:
    """The files a pull request changes since its merge base; None if git cannot tell."""
    try:
        done = subprocess.run(  # noqa: S603 (git with fixed arguments)
            ["git", "diff", "--name-only", f"{base}...{head}"],  # noqa: S607
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return [line for line in done.stdout.splitlines() if line]


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    event, base, head = argv
    changed = changed_files(base, head) if event == "pull_request" else []
    print(f"labs={'true' if labs_needed(event, changed) else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
