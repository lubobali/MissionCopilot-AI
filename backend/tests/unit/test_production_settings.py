"""Production refuses settings that would work by accident or quietly be unsafe (#103 steps 1.3,
1.8). Checked by the real server before it touches any database, so a wrong deploy stops at once
with a message saying what to fix."""

import pytest

from missioncopilot_backend.server import StartupError, build
from missioncopilot_backend.settings import Settings

pytestmark = pytest.mark.unit

SERVER = "mc.lubot.ai"


def test_production_with_only_this_machine_as_host_stops_the_start():
    # nginx sends the real host name; a localhost-only allow-list would answer every phone 400.
    with pytest.raises(StartupError, match="MISSIONCOPILOT_ALLOWED_HOSTS"):
        build({"MISSIONCOPILOT_ENV": "production"})


@pytest.mark.parametrize(
    "hosts", ["localhost", "127.0.0.1,::1", "localhost, 127.0.0.1", "localhost,127.0.0.1,::1", ""]
)
def test_local_names_alone_are_not_enough(hosts):
    settings = Settings.from_env({"MISSIONCOPILOT_ALLOWED_HOSTS": hosts})

    assert any("MISSIONCOPILOT_ALLOWED_HOSTS" in problem for problem in settings.unsafe())


def test_the_server_name_plus_loopback_for_the_healthcheck_is_fine():
    settings = Settings.from_env({"MISSIONCOPILOT_ALLOWED_HOSTS": f"{SERVER},127.0.0.1"})

    assert settings.unsafe() == []


def test_development_and_tests_keep_their_local_defaults():
    for environment in ("development", "test"):
        assert Settings.from_env({"MISSIONCOPILOT_ENV": environment}).unsafe() == []


def test_a_safe_production_setting_goes_on_to_the_next_check():
    # Past the settings, the start stops at the next missing thing: the signing key.
    with pytest.raises(StartupError, match="SIGNING_KEY"):
        build({"MISSIONCOPILOT_ENV": "production", "MISSIONCOPILOT_ALLOWED_HOSTS": SERVER})


PROXY = "192.168.250.1"


def _production(**env: str) -> Settings:
    return Settings.from_env({"MISSIONCOPILOT_ALLOWED_HOSTS": SERVER} | env)


def test_listening_beyond_this_machine_needs_a_named_proxy():
    # In a container the server listens on every address; without a trusted proxy every phone
    # would arrive as the proxy's address: one shared limit, a useless audit log.
    unsafe = _production(MISSIONCOPILOT_HOST="0.0.0.0").unsafe()  # noqa: S104

    assert [p for p in unsafe if "MISSIONCOPILOT_FORWARDED_ALLOW_IPS" in p] != []


@pytest.mark.parametrize("host", ["127.0.0.1", "::1"])
def test_this_machine_only_needs_no_proxy(host):
    assert _production(MISSIONCOPILOT_HOST=host).unsafe() == []


def test_behind_the_named_proxy_any_listen_address_is_fine():
    settings = _production(
        MISSIONCOPILOT_HOST="0.0.0.0",  # noqa: S104
        MISSIONCOPILOT_FORWARDED_ALLOW_IPS=PROXY,
    )

    assert settings.unsafe() == []


def test_a_browser_origin_without_https_is_refused_in_production():
    settings = _production(
        MISSIONCOPILOT_ALLOWED_ORIGINS="https://dash.example.org,http://dash.example.org"
    )

    # Exactly one problem, naming exactly the http origin; the https one passes.
    assert settings.unsafe() == [
        "MISSIONCOPILOT_ALLOWED_ORIGINS: http://dash.example.org is not https"
    ]
    assert _production(MISSIONCOPILOT_ALLOWED_ORIGINS="https://dash.example.org").unsafe() == []


def test_every_problem_is_reported_at_once():
    settings = Settings.from_env(
        {"MISSIONCOPILOT_HOST": "0.0.0.0", "MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE": "5"}  # noqa: S104
    )

    assert len(settings.unsafe()) == 3  # hosts, proxy, limit: one deploy fixes all of them


def test_the_start_line_says_what_runs_and_nothing_secret():
    settings = _production(
        MISSIONCOPILOT_HOST="0.0.0.0",  # noqa: S104
        MISSIONCOPILOT_PORT="8110",
        MISSIONCOPILOT_FORWARDED_ALLOW_IPS=PROXY,
    )

    line = settings.summary(signing_key_id="fake-key-id")

    assert line == (
        "MissionCopilot backend: environment=production listen=0.0.0.0:8110 "
        f"hosts={SERVER} origins=none trusted_proxy={PROXY} "
        "limits=600/min per address, 120/min per phone, body 1048576 bytes "
        "min_app_build=0 docs=off signing_key=fake-key-id"
    )


def test_the_start_line_shows_when_the_docs_pages_are_on():
    line = Settings(environment="development").summary(signing_key_id="k")

    assert "environment=development" in line
    assert "docs=on" in line
