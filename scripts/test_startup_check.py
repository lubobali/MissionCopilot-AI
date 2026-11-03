import pytest
from startup_check import check_factory, check_routes, main

pytestmark = pytest.mark.unit


def test_the_server_factory_loads():
    ok, message = check_factory("missioncopilot_backend.server:build")

    assert ok is True
    assert "loads" in message


def test_fails_cleanly_when_the_module_is_missing():
    ok, message = check_factory("missioncopilot_backend.does_not_exist:build")

    assert ok is False
    assert "does_not_exist" in message


def test_fails_cleanly_when_the_factory_is_missing():
    ok, message = check_factory("missioncopilot_backend.server:not_there")

    assert ok is False
    assert "not_there" in message


def test_the_app_builds_its_routes():
    ok, message = check_routes()

    assert ok is True
    assert "routes" in message


def test_main_passes_when_both_checks_pass(capsys):
    assert main() == 0
    assert capsys.readouterr().out.count("OK:") == 2
