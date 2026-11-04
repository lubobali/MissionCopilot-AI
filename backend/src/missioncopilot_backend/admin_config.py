"""Where the operator commands find their settings (#88, #103 step 1.5): the environment, plus the
gitignored backend/.env and secret folders when run from a repo checkout (a laptop). Installed on a
server there is no checkout: no stray .env counts, and every secret location must be named, because
a default inside the installed package would be lost with the container."""

from collections.abc import Mapping
from pathlib import Path

from missioncopilot_backend.admin_common import AdminError
from missioncopilot_backend.server import StartupError, read_setting
from missioncopilot_backend.settings import read_env_file

BACKEND = Path(__file__).resolve().parents[2]
DIRECTORY = "mc_directory"


def _in_checkout() -> bool:
    """Run from the repo (a laptop), not from an installed package (a server)."""
    return (BACKEND / "pyproject.toml").is_file()


def _merged(env: Mapping[str, str]) -> dict[str, str]:
    """The environment, over backend/.env in a checkout only: on a server no stray file counts."""
    local = read_env_file(BACKEND / ".env") if _in_checkout() else {}
    return local | dict(env)


def _secret_path(merged: Mapping[str, str], name: str, local_default: Path) -> Path:
    """Where a secret lives. The gitignored folder in a checkout; on a server it must be named: a
    default inside the installed package would be lost with the container."""
    if value := merged.get(name):
        return Path(value)
    if _in_checkout():
        return local_default
    raise AdminError(f"set {name}; outside a repo checkout there is no default")


def key_path(env: Mapping[str, str]) -> Path:
    default = BACKEND / ".keys" / "signing-key.pem"
    return _secret_path(_merged(env), "MISSIONCOPILOT_SIGNING_KEY_FILE", default)


def settings(env: Mapping[str, str]) -> tuple[str, Path, str]:
    merged = _merged(env)
    try:
        admin_url = read_setting(merged, "MISSIONCOPILOT_ADMIN_URL")
    except StartupError as error:
        raise AdminError(f"{error}; locally, run scripts/make_dev_env.py") from None
    address_dir = _secret_path(merged, "MISSIONCOPILOT_ADDRESS_DIR", BACKEND / ".db-addresses")
    return admin_url, address_dir, merged.get("MISSIONCOPILOT_DIRECTORY_DB", DIRECTORY)
