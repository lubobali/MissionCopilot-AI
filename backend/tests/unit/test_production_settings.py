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
