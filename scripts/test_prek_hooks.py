"""The Mac's commit hooks (#127, step 6.2.0.6): a commit that changes only a lab runs that lab's own
tests, not the whole app suite (2 to 4 minutes for nothing). CI still runs everything."""

import tomllib
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
HOOKS = {
    hook["id"]: hook
    for repo in tomllib.loads((ROOT / "prek.toml").read_text(encoding="utf-8"))["repos"]
    for hook in repo.get("hooks", [])
}


def test_the_app_suite_runs_for_app_changes_but_not_for_lab_only_changes():
    app = HOOKS["ios-tests"]

    assert app["files"] == "^ios/"
    assert app["exclude"] == "^ios/AILab/"


@pytest.mark.parametrize(
    ("hook", "folder"),
    [
        ("speech-lab-tests", "ios/AILab/SpeechLab/"),
        ("document-lab-tests", "ios/AILab/DocumentLab/"),
        ("encryption-lab-tests", "ios/AILab/EncryptionLab/"),
    ],
)
def test_each_lab_still_runs_its_own_tests_when_it_changes(hook, folder):
    assert folder in HOOKS[hook]["files"]
