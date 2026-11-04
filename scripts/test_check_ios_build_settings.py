"""The CI check on Xcode's own resolved settings (#104): what `xcodebuild -showBuildSettings -json`
says for Staging and Release, after every include and override, not what the files seem to say."""

import json
import subprocess
import sys
from pathlib import Path

import pytest
from check_ios_build_settings import EXPECTED, problems

pytestmark = pytest.mark.unit

GOOD = {
    "Staging": {
        "MC_SERVER_SCHEME": "https",
        "MC_SERVER_HOST": "mc-staging.lubot.ai",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.lubobali.missioncopilot.staging",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": " STAGING",
        "INFOPLIST_FILE": "Config/Info.plist",
    },
    "Release": {
        "MC_SERVER_SCHEME": "https",
        "MC_SERVER_HOST": "mc.lubot.ai",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.lubobali.missioncopilot",
        "INFOPLIST_FILE": "Config/Info.plist",
    },
}


def xcode(settings: dict) -> str:
    """The shape xcodebuild prints: a list with one entry per target."""
    return json.dumps([{"target": "MissionCopilot", "buildSettings": settings}])


@pytest.mark.parametrize("config", ["Staging", "Release"])
def test_a_good_build_passes(config):
    assert problems(config, xcode(GOOD[config])) == []


@pytest.mark.parametrize(
    ("config", "key", "value"),
    [
        ("Release", "MC_SERVER_HOST", "mc-staging.lubot.ai"),
        ("Release", "MC_SERVER_HOST", "localhost:8110"),
        ("Release", "MC_SERVER_SCHEME", "http"),
        ("Release", "PRODUCT_BUNDLE_IDENTIFIER", "com.lubobali.missioncopilot.staging"),
        ("Release", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
        ("Release", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "STAGING"),
        ("Release", "INFOPLIST_FILE", "Config/Info-Debug.plist"),
        ("Staging", "MC_SERVER_HOST", "mc.lubot.ai"),
        ("Staging", "PRODUCT_BUNDLE_IDENTIFIER", "com.lubobali.missioncopilot"),
        ("Staging", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG STAGING"),
        ("Staging", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""),
    ],
)
def test_each_wrong_setting_is_named(config, key, value):
    found = problems(config, xcode({**GOOD[config], key: value}))

    assert len(found) == 1 and key in found[0]


def test_a_missing_setting_is_named():
    settings = {k: v for k, v in GOOD["Release"].items() if k != "MC_SERVER_HOST"}

    assert problems("Release", xcode(settings)) == [
        "MC_SERVER_HOST is missing, expected mc.lubot.ai"
    ]


def test_output_that_is_not_xcodes_is_refused():
    assert problems("Release", "not json") == ["xcodebuild did not print the expected JSON"]
    assert problems("Release", "[]") == ["xcodebuild did not print the expected JSON"]


def test_only_staging_and_release_are_checked():
    assert set(EXPECTED) == {"Staging", "Release"}
    with pytest.raises(KeyError):
        problems("Debug", xcode({}))


def run(*args: str, stdin: str = "") -> subprocess.CompletedProcess:
    script = Path(__file__).with_name("check_ios_build_settings.py")
    command = [sys.executable, script, *args]
    return subprocess.run(command, input=stdin, capture_output=True, text=True)  # noqa: S603 - our own script


def test_the_command_fails_ci_on_a_wrong_build_and_passes_a_good_one():
    assert run("Release", stdin=xcode(GOOD["Release"])).returncode == 0
    bad = run("Release", stdin=xcode({**GOOD["Release"], "MC_SERVER_HOST": "localhost:8110"}))

    assert bad.returncode == 1 and "MC_SERVER_HOST" in bad.stderr


@pytest.mark.parametrize("args", [(), ("Debug",), ("Release", "Staging")])
def test_the_command_takes_only_staging_or_release(args):
    found = run(*args)

    assert found.returncode == 2 and "usage" in found.stderr
