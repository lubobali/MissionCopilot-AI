"""Settings fail safe: with nothing configured the backend runs as production, and a typo in the
environment name stops the start instead of silently running with the wrong rules."""

import pytest

from missioncopilot_backend.settings import Settings

pytestmark = pytest.mark.unit


def test_nothing_configured_means_production():
    assert Settings.from_env({}).environment == "production"


def test_environment_is_read_from_the_environment_variable():
    assert Settings.from_env({"MISSIONCOPILOT_ENV": "development"}).environment == "development"


def test_an_unknown_environment_stops_the_start():
    with pytest.raises(ValueError, match="MISSIONCOPILOT_ENV"):
        Settings.from_env({"MISSIONCOPILOT_ENV": "prod"})


@pytest.mark.parametrize(("environment", "docs"), [("production", False), ("development", True)])
def test_api_docs_only_outside_production(environment, docs):
    assert Settings(environment=environment).docs_enabled is docs
