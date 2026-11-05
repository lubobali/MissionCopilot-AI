"""The app's three builds (#104): Debug talks to the local server for the Simulator, Staging to
the staging server, Release only to production. Each build has its own xcconfig that starts from
Base (which pulls in the git-ignored Local.xcconfig) and then sets its server; Apple's rule is that
the last assignment wins, so a laptop's Local.xcconfig can never point Staging or Release at the
laptop. Staging is its own app on the phone (own bundle id, so its own keychain and chip keys,
never production's)."""

import hashlib
import re
from pathlib import Path

import pytest
import yaml
from check_ios_build_settings import EXPECTED
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "ios" / "Config"
PROJECT = yaml.safe_load((ROOT / "ios" / "project.yml").read_text(encoding="utf-8"))
APP = PROJECT["targets"]["MissionCopilot"]
SERVERS = {"Staging": "mc-staging.lubot.ai", "Release": "mc.lubot.ai"}
# What a developer's Local.xcconfig says (#90): the laptop's server over plain http.
LAPTOP = "MC_SERVER_SCHEME = http\nMC_SERVER_HOST = localhost:8110\nMC_SERVER_KEYS = 3059\n"


def resolve(name: str, local: str | None) -> dict[str, str]:
    """The settings an xcconfig gives, read the way Xcode does: includes in place, last one wins."""
    settings: dict[str, str] = {}
    for line in _lines(name, local):
        key, _, value = line.partition("=")
        settings[key.strip()] = value.strip()
    return settings


def _lines(name: str, local: str | None) -> list[str]:
    if name == "Local.xcconfig":
        return _lines_of(local) if local is not None else []
    lines = []
    for line in _lines_of((CONFIG / name).read_text(encoding="utf-8")):
        include = re.fullmatch(r'#include(\?)?\s+"([^"]+)"', line)
        if include:
            lines += _lines(include.group(2), local)
        else:
            lines.append(line)
    return lines


def _lines_of(text: str) -> list[str]:
    stripped = (line.split("//")[0].strip() for line in text.splitlines())
    return [line for line in stripped if line and (line.startswith("#include") or "=" in line)]


def test_there_are_three_builds_each_with_its_own_settings_file():
    assert PROJECT["configs"] == {"Debug": "debug", "Staging": "release", "Release": "release"}
    assert PROJECT["configFiles"] == {
        name: f"Config/{name}.xcconfig" for name in PROJECT["configs"]
    }


@pytest.mark.parametrize("name", ["Debug", "Staging", "Release"])
def test_every_build_starts_from_base(name):
    assert (
        _lines_of((CONFIG / f"{name}.xcconfig").read_text(encoding="utf-8"))[0]
        == '#include "Base.xcconfig"'
    )


@pytest.mark.parametrize("name", ["Staging", "Release"])
@pytest.mark.parametrize("local", [None, LAPTOP], ids=["no local file", "laptop local file"])
def test_staging_and_release_talk_only_to_their_own_server_over_https(name, local):
    settings = resolve(f"{name}.xcconfig", local)

    assert settings["MC_SERVER_SCHEME"] == "https"
    assert settings["MC_SERVER_HOST"] == SERVERS[name]


def test_debug_uses_the_laptop_server_from_the_local_file_and_has_none_without_it():
    assert resolve("Debug.xcconfig", LAPTOP)["MC_SERVER_HOST"] == "localhost:8110"
    assert resolve("Debug.xcconfig", None)["MC_SERVER_HOST"] == ""


def test_the_signing_team_still_comes_from_the_local_file_in_every_build():
    for name in PROJECT["configs"]:
        assert resolve(f"{name}.xcconfig", "DEVELOPMENT_TEAM = ABC\n")["DEVELOPMENT_TEAM"] == "ABC"


def test_the_server_is_set_only_in_the_settings_files():
    # Target settings beat xcconfig files: a server set in project.yml would win over all of this.
    settings = [APP["settings"]["base"], *APP["settings"].get("configs", {}).values()]
    assert not any(key.startswith("MC_SERVER") for block in settings for key in block)


def test_staging_is_its_own_app_on_the_phone():
    staging = APP["settings"]["configs"]["Staging"]

    assert staging["PRODUCT_BUNDLE_IDENTIFIER"] == "com.lubobali.missioncopilot.staging"
    assert staging["INFOPLIST_KEY_CFBundleDisplayName"] == "MC Staging"
    assert staging["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] == "$(inherited) STAGING"
    assert APP["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] == "com.lubobali.missioncopilot"
    assert "Release" not in APP["settings"]["configs"]


def test_the_main_scheme_tests_debug_and_archives_release_and_staging_has_its_own():
    main, staging = (
        PROJECT["schemes"]["MissionCopilot"],
        PROJECT["schemes"]["MissionCopilot Staging"],
    )

    assert (main["run"]["config"], main["test"]["config"], main["archive"]["config"]) == (
        "Debug",
        "Debug",
        "Release",
    )
    assert (staging["run"]["config"], staging["archive"]["config"]) == ("Staging", "Staging")
    assert "test" not in staging  # the tests need a debug build (testability)


def test_the_app_checks_the_same_servers_as_the_settings_files():
    # ServerConfig.server(staging:debug:) is the app's second lock (#104); it must not drift.
    swift = (ROOT / "ios/MissionCopilot/Platform/Network/ServerConfig.swift").read_text("utf-8")
    rule = re.search(r"static func server\(staging: Bool, debug: Bool\).*?\n    \}", swift, re.S)

    assert rule is not None
    assert re.findall(r'"([^"]+)"', rule.group(0)) == [SERVERS["Staging"], SERVERS["Release"]]


@pytest.mark.parametrize("name", ["Staging", "Release"])
def test_staging_and_release_name_a_real_server(name):
    host = resolve(f"{name}.xcconfig", LAPTOP)["MC_SERVER_HOST"]

    assert re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", host)  # a name: no port, path or scheme
    assert not re.fullmatch(r"[0-9.]+", host)  # not an IP address (iOS refuses those over ATS)
    assert "localhost" not in host and not host.endswith(".local")


def test_only_debug_has_the_local_network_exception():
    # Staging and Release use Info.plist, which has no transport security exception at all.
    configs = APP["settings"]["configs"]

    assert configs["Debug"]["INFOPLIST_FILE"] == "Config/Info-Debug.plist"
    assert all("INFOPLIST_FILE" not in configs[name] for name in configs if name != "Debug")


def test_the_ci_check_expects_the_same_servers_and_app_ids():
    assert {name: EXPECTED[name]["MC_SERVER_HOST"] for name in EXPECTED} == SERVERS
    staging = APP["settings"]["configs"]["Staging"]["PRODUCT_BUNDLE_IDENTIFIER"]
    assert EXPECTED["Staging"]["PRODUCT_BUNDLE_IDENTIFIER"] == staging
    release = APP["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
    assert EXPECTED["Release"]["PRODUCT_BUNDLE_IDENTIFIER"] == release


def test_each_build_compiles_in_its_own_server_rule():
    # The unit tests run as Debug, so they cannot see the Staging or Release branch; this reads it.
    swift = (ROOT / "ios/MissionCopilot/Platform/Network/ServerConfig.swift").read_text("utf-8")
    block = re.search(r"static let buildServer: String\? = \{(.*?)\}\(\)", swift, re.S)

    assert block is not None
    branches = re.findall(r"#(if STAGING|elseif DEBUG|else)\s+server\(([^)]*)\)", block.group(1))
    assert branches == [
        ("if STAGING", "staging: true, debug: false"),
        ("elseif DEBUG", "staging: false, debug: true"),
        ("else", "staging: false, debug: false"),
    ]


def test_the_build_number_is_a_whole_number_the_server_can_compare():
    # The server reads X-App-Build as digits only; "1.0" or "2b" would count as too old (#104).
    build = PROJECT["settings"]["base"]["CURRENT_PROJECT_VERSION"]

    assert isinstance(build, str) and build.isdigit() and int(build) >= 2


# The keys each build pins, by key id (the first 16 hex digits of the SHA-256 of the DER key, as the
# server's pack_format.key_id and the phone's ServerConfig.keyId name them).
# Release: the live key and the offline spare (#103 step 6.5).
PINNED = {"Staging": {"4bf338c69bae5bfa"}, "Release": {"961f36f2f593bc81", "6846cc2ed260cde7"}}


@pytest.mark.parametrize("name", ["Staging", "Release"])
def test_each_build_pins_exactly_its_servers_public_keys(name):
    keys = resolve(f"{name}.xcconfig", LAPTOP)["MC_SERVER_KEYS"].split()

    assert {hashlib.sha256(bytes.fromhex(key)).hexdigest()[:16] for key in keys} == PINNED[name]
    for key in keys:
        public = serialization.load_der_public_key(bytes.fromhex(key))
        assert isinstance(public, ec.EllipticCurvePublicKey) and public.curve.name == "secp256r1"


def test_staging_and_release_never_pin_the_same_key():
    staging = set(resolve("Staging.xcconfig", None)["MC_SERVER_KEYS"].split())
    release = set(resolve("Release.xcconfig", None)["MC_SERVER_KEYS"].split())

    assert not staging & release


def test_every_shred_order_is_judged_by_the_servers_time():
    # #94: with now: Date() a phone whose clock is wrong refuses its genuine shred order.
    app = ROOT / "ios" / "MissionCopilot" / "App"
    calls = [
        call
        for path in app.glob("*.swift")
        for call in re.findall(
            r"ShredOrderAction\.handle\(.*?now:[^\n]*", path.read_text("utf-8"), re.S
        )
    ]

    assert calls and all("now: Connection.serverNow()" in call for call in calls)


def test_a_destroyed_list_keeps_the_shred_notice():
    # #94: the hub forgot the list without saying why, so the screen stayed on "Loading missions".
    hub = (ROOT / "ios/MissionCopilot/App/MissionsHub.swift").read_text("utf-8")

    assert "if case .destroyed(let count) = result { hub?.forget(destroyed: count) }" in hub
