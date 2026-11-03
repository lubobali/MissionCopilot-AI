"""What the operator commands share (#88, #90): their one error, and finding the directory."""

from pathlib import Path

from psycopg.conninfo import conninfo_to_dict, make_conninfo


class AdminError(Exception):
    """The command cannot go on; the message says why."""


def directory_url(address_dir: Path) -> str:
    """The directory's app login address, as setup wrote it."""
    path = address_dir / "directory.url"
    if not path.exists():
        raise AdminError("no directory yet; run setup first")
    return path.read_text(encoding="utf-8").strip()


def as_admin(admin_url: str, app_url: str) -> str:
    """The admin's address into the same database as an app login's address."""
    return make_conninfo(admin_url, dbname=conninfo_to_dict(app_url)["dbname"])
