"""The iOS workflow checks that the Staging and Release builds talk only to their own server (#104
step 104.3b, asked for on #103). Xcode resolves the settings after every include and override;
scripts/check_ios_build_settings.py (the Mac session's) checks what it resolved. This pins that the
step runs, right after the project is generated, for both builds, and that a change to the checker
itself runs the workflow."""

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

FLOW = yaml.safe_load(
    (Path(__file__).resolve().parents[3] / ".github/workflows/ios.yml").read_text("utf-8")
)
ON = FLOW[True]  # YAML 1.1 reads the key `on` as True
STEPS = FLOW["jobs"]["ios"]["steps"]
CHECK = "Staging and Release talk only to their own server (#104)"


def _names() -> list[str]:
    return [step.get("name", step.get("uses", "")) for step in STEPS]


def test_the_build_settings_are_checked_right_after_the_project_is_generated():
    names = _names()

    assert names.index(CHECK) == names.index("Generate Xcode project from project.yml") + 1


def test_both_builds_are_checked_by_the_macs_checker():
    step = STEPS[_names().index(CHECK)]

    assert step["working-directory"] == "ios"
    assert "for config in Staging Release; do" in step["run"]
    assert "xcodebuild -showBuildSettings -json -project MissionCopilot.xcodeproj" in step["run"]
    assert (
        'python3 "$GITHUB_WORKSPACE/scripts/check_ios_build_settings.py" "$config"' in step["run"]
    )
    assert "set -euo pipefail" in step["run"]  # a failing check fails the step (pipefail)


def test_a_change_to_the_checker_runs_the_workflow():
    for event in ("push", "pull_request"):
        assert "scripts/check_ios_build_settings.py" in ON[event]["paths"]
        assert "ios/**" in ON[event]["paths"]
