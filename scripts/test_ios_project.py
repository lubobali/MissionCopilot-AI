"""The main app's security settings live in ios/project.yml (XcodeGen), not in code, so a test
pins them: the minimum iOS version (MASVS-CODE-1, #61) and file protection Complete for every file
the app creates (ADR 0008 layer A). Dropping either fails here, not on someone's phone. CI picks a
simulator that can run it."""

from pathlib import Path

import pytest
import yaml
from newest_iphone import newest_iphone

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
PROJECT = yaml.safe_load((ROOT / "ios" / "project.yml").read_text(encoding="utf-8"))
APP = PROJECT["targets"]["MissionCopilot"]


def test_the_app_requires_ios_26_or_later():
    major = int(str(PROJECT["options"]["deploymentTarget"]["iOS"]).split(".")[0])

    assert major >= 26


def test_every_file_the_app_creates_is_protected_complete():
    properties = APP["entitlements"]["properties"]

    assert properties["com.apple.developer.default-data-protection"] == "NSFileProtectionComplete"


RUNTIMES = {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [{"udid": "old", "name": "iPhone 16"}],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
        {"udid": "ipad", "name": "iPad Air"},
        {"udid": "new", "name": "iPhone 17"},
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [{"udid": "newest", "name": "iPhone 17 Pro"}],
    "com.apple.CoreSimulator.SimRuntime.watchOS-26-2": [{"udid": "watch", "name": "Apple Watch"}],
}


def test_ci_picks_an_iphone_on_the_newest_ios_runtime():
    # An iOS 26 app cannot run on an older simulator the runner might list first; 26.10 > 26.2.
    assert newest_iphone({"devices": RUNTIMES}) == "newest"


def test_ci_skips_runtimes_without_an_iphone():
    devices = {k: v for k, v in RUNTIMES.items() if k.endswith(("18-5", "26-2"))}

    assert newest_iphone({"devices": devices}) == "new"


def test_no_iphone_at_all_is_an_error():
    with pytest.raises(SystemExit):
        newest_iphone({"devices": {}})


def test_the_workflow_uses_the_picker():
    workflow = (ROOT / ".github" / "workflows" / "ios.yml").read_text(encoding="utf-8")

    assert "scripts/newest_iphone.py" in workflow
    assert "startswith('iPhone')" not in workflow  # no step keeps the old first-listed picker


def test_ci_signs_the_app_tests_ad_hoc_so_the_keychain_works():
    workflow = (ROOT / ".github" / "workflows" / "ios.yml").read_text(encoding="utf-8")
    step = workflow[workflow.index("Test on an iPhone simulator") :]
    step = step[: step.index("- name:")]

    assert "CODE_SIGN_IDENTITY=-" in step
    assert "CODE_SIGNING_ALLOWED=NO" not in step
