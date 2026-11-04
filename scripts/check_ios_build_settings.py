"""Checks Xcode's own resolved settings for the Staging and Release builds (#104), after every
include and override, so CI refuses a build that would talk to the wrong server, over plain http, as
the wrong app, or with the local network exception. Read from `xcodebuild -showBuildSettings -json`:

    xcodebuild -showBuildSettings -json -project MissionCopilot.xcodeproj -target MissionCopilot \
        -configuration Release | python3 scripts/check_ios_build_settings.py Release
"""

import json
import sys

# What each build must resolve to. Conditions: the Swift flags it must and must not have.
EXPECTED = {
    "Staging": {
        "MC_SERVER_SCHEME": "https",
        "MC_SERVER_HOST": "mc-staging.lubot.ai",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.lubobali.missioncopilot.staging",
        "INFOPLIST_FILE": "Config/Info.plist",
        "conditions": {"STAGING"},
    },
    "Release": {
        "MC_SERVER_SCHEME": "https",
        "MC_SERVER_HOST": "mc.lubot.ai",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.lubobali.missioncopilot",
        "INFOPLIST_FILE": "Config/Info.plist",
        "conditions": set(),
    },
}
FLAGS = {"DEBUG", "STAGING"}


def problems(config: str, output: str) -> list[str]:
    """What is wrong with the build `config`, given xcodebuild's JSON; empty when all is right."""
    expected = EXPECTED[config]
    try:
        settings = json.loads(output)[0]["buildSettings"]
    except (ValueError, LookupError, TypeError):
        return ["xcodebuild did not print the expected JSON"]
    found = []
    for key, want in expected.items():
        if key == "conditions":
            continue
        if key not in settings:
            found.append(f"{key} is missing, expected {want}")
        elif settings[key] != want:
            found.append(f"{key} is {settings[key]!r}, expected {want}")
    flags = set(settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()) & FLAGS
    if flags != expected["conditions"]:
        found.append(
            f"SWIFT_ACTIVE_COMPILATION_CONDITIONS has {sorted(flags)}, "
            f"expected {sorted(expected['conditions'])}"
        )
    return found


def main() -> int:
    config = sys.argv[1] if len(sys.argv) == 2 else ""
    if config not in EXPECTED:
        print(f"usage: check_ios_build_settings.py {' | '.join(EXPECTED)}", file=sys.stderr)
        return 2
    found = problems(config, sys.stdin.read())
    for problem in found:
        print(f"{config}: {problem}", file=sys.stderr)
    if not found:
        print(f"{config}: server, app id, Info file and Swift flags are right")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
