import subprocess
import sys
from pathlib import Path

import pytest
from ios_ci_paths import labs_needed

pytestmark = pytest.mark.unit

SCRIPT = Path(__file__).resolve().parent / "ios_ci_paths.py"


@pytest.mark.parametrize(
    "changed",
    [
        ["ios/AILab/EncryptionLab/Package.swift"],
        ["ios/AILab/DocumentLab/Sources/DocumentLab/Grounding.swift"],
        ["docs/demo/scans/invoice-14.png"],
        ["docs/demo/audio/debrief-en.m4a"],
        [".github/workflows/ios.yml"],
        ["scripts/newest_iphone.py"],  # the labs pick their simulator with it
        ["scripts/ios_ci_paths.py"],  # a change to this rule runs everything once
    ],
)
def test_a_pr_that_touches_what_the_labs_use_runs_them(changed):
    assert labs_needed("pull_request", changed)


@pytest.mark.parametrize(
    "changed",
    [
        ["ios/MissionCopilot/App/MissionWorkspace.swift"],
        ["ios/MissionCopilotTests/BrandTests.swift", "ios/project.yml"],
        ["docs/design/theme.md", "README.md"],
    ],
)
def test_a_pr_that_changes_only_the_app_skips_the_labs(changed):
    assert not labs_needed("pull_request", changed)


@pytest.mark.parametrize("event", ["push", "schedule", "workflow_dispatch"])
def test_main_the_weekly_run_and_a_manual_run_always_run_the_labs(event):
    # The full safety net: every lab test still runs on every push to main and once a week.
    assert labs_needed(event, [])


def test_an_unknown_event_runs_everything():
    # When in doubt, run the tests: skipping is only ever a choice for a known pull request.
    assert labs_needed("merge_group", ["ios/MissionCopilot/App/ContentView.swift"])


def test_a_pr_whose_changes_cannot_be_listed_runs_everything():
    assert labs_needed("pull_request", None)


def _git(repo: Path, *args: str) -> str:
    run = subprocess.run(  # noqa: S603 (git with fixed arguments in a test repo)
        ["git", "-C", str(repo), *args],  # noqa: S607
        capture_output=True,
        text=True,
        check=True,
    )
    return run.stdout.strip()


def _commit(repo: Path, path: str, text: str) -> str:
    (repo / path).parent.mkdir(parents=True, exist_ok=True)
    (repo / path).write_text(text)
    _git(repo, "add", path)
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", path)
    return _git(repo, "rev-parse", "HEAD")


def test_the_command_line_compares_the_whole_pr_with_its_base(tmp_path):
    # A lab change in the first commit of a PR still counts after a later app-only commit.
    _git(tmp_path, "init", "-q")
    base = _commit(tmp_path, "README.md", "start")
    _commit(tmp_path, "ios/AILab/SpeechLab/Package.swift", "lab")
    head = _commit(tmp_path, "ios/MissionCopilot/App/ContentView.swift", "app")

    def run(start: str) -> str:
        done = subprocess.run(  # noqa: S603 (our own script, fixed arguments)
            [sys.executable, str(SCRIPT), "pull_request", start, head],
            capture_output=True,
            text=True,
            check=True,
            cwd=tmp_path,
        )
        return done.stdout.strip()

    assert run(base) == "labs=true"
    assert run(_git(tmp_path, "rev-parse", "HEAD~1")) == "labs=false"


def test_lab_changes_merged_to_main_after_the_pr_started_do_not_count_as_the_prs(tmp_path):
    # GitHub gives the base branch's tip: comparing from the merge base keeps main's own later
    # changes out, so an app-only PR still skips the labs (two dots would run them for nothing).
    _git(tmp_path, "init", "-q", "-b", "main")
    _commit(tmp_path, "README.md", "start")
    _git(tmp_path, "checkout", "-q", "-b", "story")
    head = _commit(tmp_path, "ios/MissionCopilot/App/ContentView.swift", "app")
    _git(tmp_path, "checkout", "-q", "main")
    base = _commit(tmp_path, "ios/AILab/SpeechLab/Package.swift", "lab merged meanwhile")

    done = subprocess.run(  # noqa: S603 (our own script, fixed arguments)
        [sys.executable, str(SCRIPT), "pull_request", base, head],
        capture_output=True,
        text=True,
        check=True,
        cwd=tmp_path,
    )

    assert done.stdout.strip() == "labs=false"


def test_the_command_line_runs_everything_when_git_cannot_answer(tmp_path):
    done = subprocess.run(  # noqa: S603 (our own script, fixed arguments)
        [sys.executable, str(SCRIPT), "pull_request", "0" * 40, "1" * 40],
        capture_output=True,
        text=True,
        check=False,
        cwd=tmp_path,
    )

    assert done.returncode == 0
    assert done.stdout.strip() == "labs=true"
