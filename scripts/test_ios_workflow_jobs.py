"""The iOS workflow's jobs (#127, steps 6.2.0.2 and 6.2.0.4): the app and the labs run in parallel,
the labs only when the rule in ios_ci_paths.py says so, one "iOS result" says whether everything
needed passed, and each macOS job boots its simulator first, while the rest of the job runs (the
simulator's cold boot was about 6 of the app step's 10.5 minutes)."""

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
FLOW = yaml.safe_load((ROOT / ".github" / "workflows" / "ios.yml").read_text(encoding="utf-8"))
ON = FLOW[True]  # YAML 1.1 reads the key `on` as True
JOBS = FLOW["jobs"]


def _names(job: str) -> list[str]:
    return [step.get("name", step.get("uses", "")) for step in JOBS[job]["steps"]]


def _step(job: str, name: str) -> dict:
    return JOBS[job]["steps"][_names(job).index(name)]


def test_the_jobs_are_the_rule_the_app_the_labs_and_one_result():
    assert set(JOBS) == {"changes", "ios", "labs", "result"}


def test_the_rule_runs_on_linux_with_no_permissions_and_sees_the_whole_history():
    changes = JOBS["changes"]

    assert changes["runs-on"].startswith("ubuntu-")
    assert changes["permissions"] == {}
    checkout = changes["steps"][0]
    assert checkout["with"]["fetch-depth"] == 0  # the PR's merge base must be there
    assert checkout["with"]["persist-credentials"] is False


def test_the_rule_reads_the_event_from_the_environment_never_spliced_into_the_script():
    step = _step("changes", "Do the labs need to run? (scripts/ios_ci_paths.py)")

    assert "${{" not in step["run"]  # no template injection (zizmor)
    assert (
        'python3 scripts/ios_ci_paths.py "$EVENT" "$BASE" "$HEAD" >> "$GITHUB_OUTPUT"'
        in step["run"]
    )
    assert step["env"]["EVENT"] == "${{ github.event_name }}"
    assert JOBS["changes"]["outputs"]["labs"] == "${{ steps.rule.outputs.labs }}"


def test_the_labs_run_only_when_the_rule_says_so_and_in_parallel_with_the_app():
    labs = JOBS["labs"]

    assert labs["needs"] == ["changes"]
    assert labs["if"] == "needs.changes.outputs.labs == 'true'"
    assert "needs" not in JOBS["ios"]  # the app starts at once, beside the rule


def test_every_lab_test_script_still_runs_in_the_labs_job():
    run = "\n".join(step.get("run", "") for step in JOBS["labs"]["steps"])

    for lab in ("EncryptionLab", "DocumentLab", "SpeechLab"):
        assert f"ios/AILab/{lab}/test.sh" in run
    assert not any("ios/AILab/" in step.get("run", "") for step in JOBS["ios"]["steps"])


def test_one_result_is_green_only_when_every_needed_job_passed():
    result = JOBS["result"]

    assert result["name"] == "iOS result"
    assert result["if"] == "always()"
    assert result["needs"] == ["changes", "ios", "labs"]
    assert result["permissions"] == {}
    run = result["steps"][0]["run"]
    assert "failure" in run and "cancelled" in run
    assert "${{" not in run  # the results come in through env


def test_the_full_safety_net_runs_weekly_and_on_demand():
    assert ON["schedule"] == [{"cron": "0 6 * * 1"}]  # Mondays 06:00 UTC: every lab test
    assert "workflow_dispatch" in ON


BOOT = "Boot the simulator"
SETTINGS = "Staging and Release talk only to their own server (#104)"


def test_the_app_job_boots_after_the_build_never_beside_it():
    # Measured twice (#127): on the 3-core runner a simulator's first boot beside other work slowed
    # both (lint and checks about 50 s to 5 min; build 113 s to about 290 s), so it runs on its own.
    names = _names("ios")
    build, boot = names.index("Build the app for testing"), names.index(BOOT)
    assert names.index(SETTINGS) < build < boot < names.index("Test on an iPhone simulator")


def test_the_labs_job_boots_before_its_tests():
    names = _names("labs")
    assert names.index(BOOT) < names.index("Encryption lab tests (spike 16, SQLCipher + Keychain)")


@pytest.mark.parametrize("job", ["ios", "labs"])
def test_the_boot_step_picks_boots_and_waits_in_one_place(job):
    run = _step(job, BOOT)["run"]

    assert "nohup" not in run and not run.rstrip().endswith("&")  # nothing in the background
    assert 'xcrun simctl bootstatus "$udid" -b' in run  # boots it and waits until it is ready
    assert 'echo "UDID=$udid" >> "$GITHUB_ENV"' in run


@pytest.mark.parametrize("job", ["ios", "labs"])
def test_the_simulator_is_picked_once_and_used_everywhere(job):
    run = "\n".join(step.get("run", "") for step in JOBS[job]["steps"])

    assert run.count("scripts/newest_iphone.py") == 1
