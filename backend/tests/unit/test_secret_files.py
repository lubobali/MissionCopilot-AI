"""Secrets the server or the admin cannot read stop with one clear line, never a traceback (#103
step 1.5, B2, B10, N7). In a container the server runs as its own user: a secret owned by root
passes the 0600 check but cannot be opened, and the message must say how to fix it. Outside a repo
checkout (an installed package on a server) the admin has no default folder for secrets: a default
inside the installed package would put passwords and the signing key where a new container loses
them."""

import os
from pathlib import Path

import pytest

from missioncopilot_backend import admin, admin_config
from missioncopilot_backend.server import StartupError, read_setting
from missioncopilot_backend.signing_key import SigningKeyError, load_signing_key

pytestmark = pytest.mark.unit

DIRECTORY = "MISSIONCOPILOT_DIRECTORY_URL"


def _no_permission(self, *args, **kwargs):
    raise PermissionError(13, "Permission denied")


@pytest.mark.parametrize(
    "make", [lambda p: None, lambda p: p.mkdir(mode=0o700)], ids=["missing", "folder"]
)
def test_a_secret_file_that_cannot_be_read_stops_the_server_clearly(tmp_path, make):
    path = tmp_path / "directory.url"
    make(path)

    with pytest.raises(StartupError, match=f"{path} cannot be read"):
        read_setting({f"{DIRECTORY}_FILE": str(path)}, DIRECTORY)


def test_a_secret_owned_by_another_user_says_whose_it_must_be(tmp_path, monkeypatch):
    path = tmp_path / "directory.url"
    path.write_text("host=postgres")
    os.chmod(path, 0o600)
    monkeypatch.setattr(Path, "read_text", _no_permission)

    with pytest.raises(StartupError, match=f"owned by the server's user \\(uid {os.getuid()}\\)"):
        read_setting({f"{DIRECTORY}_FILE": str(path)}, DIRECTORY)


def test_a_signing_key_that_cannot_be_read_is_a_clear_refusal(tmp_path, monkeypatch):
    path = tmp_path / "signing-key.pem"
    path.write_text("not read")
    os.chmod(path, 0o600)
    monkeypatch.setattr(Path, "read_bytes", _no_permission)

    with pytest.raises(SigningKeyError, match="cannot be read"):
        load_signing_key(path)


def test_a_signing_key_path_that_is_a_folder_is_a_clear_refusal(tmp_path):
    (tmp_path / "signing-key.pem").mkdir(mode=0o700)

    with pytest.raises(SigningKeyError, match="cannot be read"):
        load_signing_key(tmp_path / "signing-key.pem")


@pytest.fixture
def installed(tmp_path, monkeypatch) -> Path:
    """The admin as installed on a server: its package folder is no repo checkout."""
    site = tmp_path / "site-packages"
    site.mkdir()
    (site / ".env").write_text("MISSIONCOPILOT_ADMIN_URL=postgresql://from-a-stray-env-file\n")
    monkeypatch.setattr(admin_config, "BACKEND", site)
    return site


def test_outside_a_checkout_the_signing_key_needs_its_setting(installed, capsys):
    assert admin.main(["make-signing-key"], {}) == 1

    assert "MISSIONCOPILOT_SIGNING_KEY_FILE" in capsys.readouterr().err
    assert list(installed.rglob("*.pem")) == []  # nothing written inside the package


def test_outside_a_checkout_the_secrets_folder_needs_its_setting(installed, capsys):
    env = {"MISSIONCOPILOT_ADMIN_URL": "postgresql://admin@postgres/postgres"}

    assert admin.main(["setup"], env) == 1
    assert "MISSIONCOPILOT_ADDRESS_DIR" in capsys.readouterr().err


def test_outside_a_checkout_no_env_file_is_read(installed, capsys):
    assert admin.main(["migrate"], {}) == 1
    assert "MISSIONCOPILOT_ADMIN_URL" in capsys.readouterr().err  # the stray .env was ignored


def test_in_a_checkout_the_local_defaults_still_apply(tmp_path, monkeypatch, capsys):
    checkout = tmp_path / "backend"
    checkout.mkdir()
    (checkout / "pyproject.toml").write_text('[project]\nname = "missioncopilot-backend"\n')
    monkeypatch.setattr(admin_config, "BACKEND", checkout)

    assert admin.main(["make-signing-key"], {}) == 0
    assert (checkout / ".keys" / "signing-key.pem").exists()


def test_a_missing_input_file_is_one_failed_line(tmp_path, capsys):
    assert admin.main(["convert-checklist", str(tmp_path / "missing.xlsx")]) == 1

    err = capsys.readouterr().err
    assert err.startswith("FAILED: FileNotFoundError: ")
    assert err.count("\n") == 1  # one line, no traceback


def test_a_database_error_is_one_failed_line_without_the_password(tmp_path, capsys):
    (tmp_path / "directory.url").write_text("host=127.0.0.1 port=1 dbname=mc_directory\n")
    env = {
        "MISSIONCOPILOT_ADMIN_URL": "postgresql://admin:s3cret-pw@127.0.0.1:1/postgres",
        "MISSIONCOPILOT_ADDRESS_DIR": str(tmp_path),
    }

    assert admin.main(["migrate"], env) == 1

    err = capsys.readouterr().err
    # The named address folder was used (its directory.url points at port 1), and the database
    # refusal comes back as one line naming the error, never the password.
    assert err.startswith("FAILED: OperationalError: connection failed")
    assert err.count("\n") == 1
    assert "s3cret-pw" not in err
