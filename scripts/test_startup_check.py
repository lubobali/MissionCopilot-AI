import pytest
from startup_check import check_app

pytestmark = pytest.mark.unit


def test_reports_route_count_when_the_app_loads():
    ok, message = check_app("missioncopilot_backend.app:app")

    assert ok is True
    assert "routes" in message


def test_fails_cleanly_when_the_module_is_missing():
    ok, message = check_app("missioncopilot_backend.does_not_exist:app")

    assert ok is False
    assert "does_not_exist" in message


def test_fails_cleanly_when_the_app_object_is_missing():
    ok, message = check_app("missioncopilot_backend.app:not_there")

    assert ok is False
    assert "not_there" in message
