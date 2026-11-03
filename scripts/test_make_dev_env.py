import stat

import pytest
from make_dev_env import PORT, read_env, write_dev_env

pytestmark = pytest.mark.unit


def test_it_writes_a_random_admin_password_and_the_test_address(tmp_path):
    env = tmp_path / ".env"

    assert write_dev_env(env) is True

    values = read_env(env)
    password = values["MISSIONCOPILOT_PG_ADMIN_PASSWORD"]
    assert len(password) == 48 and int(password, 16) >= 0
    url = f"postgresql://missioncopilot_admin:{password}@127.0.0.1:{PORT}/postgres"
    assert values["MISSIONCOPILOT_TEST_ADMIN_URL"] == url


def test_every_machine_gets_its_own_password(tmp_path):
    write_dev_env(tmp_path / "a.env")
    write_dev_env(tmp_path / "b.env")

    first = read_env(tmp_path / "a.env")["MISSIONCOPILOT_PG_ADMIN_PASSWORD"]
    assert first != read_env(tmp_path / "b.env")["MISSIONCOPILOT_PG_ADMIN_PASSWORD"]


def test_an_existing_file_is_never_overwritten(tmp_path):
    env = tmp_path / ".env"
    env.write_text("MISSIONCOPILOT_PG_ADMIN_PASSWORD=keep\n")

    assert write_dev_env(env) is False
    assert env.read_text() == "MISSIONCOPILOT_PG_ADMIN_PASSWORD=keep\n"


def test_only_the_owner_can_read_it(tmp_path):
    env = tmp_path / ".env"
    write_dev_env(env)

    assert stat.S_IMODE(env.stat().st_mode) == 0o600


def test_reading_skips_comments_and_blank_lines(tmp_path):
    env = tmp_path / ".env"
    env.write_text("# A=old value, commented out\n\nA=1\nB = two=2\n")

    assert read_env(env) == {"A": "1", "B": "two=2"}


def test_reading_a_missing_file_gives_nothing(tmp_path):
    assert read_env(tmp_path / "none.env") == {}
