"""Operator commands (#88): set up the directory, add an organization, migrate, load the demo.

Usage (uv run --directory backend missioncopilot-admin <command>):
  setup              the directory database and its own login (once)
  add-org <org id>   an organization's database, logins and address file
  migrate            every database up to the code's migrations (the server never does this itself)
  seed-demo          the fictional Kandor organization, two missions and their teams

The Postgres admin address comes from MISSIONCOPILOT_ADMIN_URL (or _FILE); locally, backend/.env.
The directory database is mc_directory unless MISSIONCOPILOT_DIRECTORY_DB names another.
Addresses with passwords go into MISSIONCOPILOT_SECRETS_DIR (default backend/.secrets, gitignored):
directory.url and orgs/<org id>.url, each readable by its owner only and never printed. Start the
server with MISSIONCOPILOT_DIRECTORY_URL_FILE=<dir>/directory.url and
MISSIONCOPILOT_ORG_URLS_DIR=<dir>/orgs.
"""

import argparse
import os
import sys
from collections.abc import Mapping
from pathlib import Path

import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.migrations import load, migrate
from missioncopilot_backend.db.missions import ORG_MIGRATIONS
from missioncopilot_backend.db.organizations import (
    create_database,
    harden_cluster,
    names_for,
    provision,
)
from missioncopilot_backend.server import StartupError, read_setting
from missioncopilot_backend.settings import read_env_file

BACKEND = Path(__file__).resolve().parents[2]
DIRECTORY = "mc_directory"
DEMO_ORG = "kandor-works"
DEMO = {  # fictional: Kandor is not a real country
    "kandor-roads": ("Kandor Rural Roads Project, Package 1", ("officer-7", "manager-1")),
    "kandor-bridges": ("Kandor Bridges", ("officer-8", "manager-1")),
}


class AdminError(Exception):
    """The command cannot go on; the message says why."""


def _write_secret(path: Path, text: str) -> None:
    """Owner-only, and never over an existing file."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise AdminError(f"{path} already exists; not overwriting it") from None
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(text + "\n")


def _directory_url(secrets: Path) -> str:
    path = secrets / "directory.url"
    if not path.exists():
        raise AdminError("no directory yet; run setup first")
    return path.read_text(encoding="utf-8").strip()


def _as_admin(admin_url: str, app_url: str) -> str:
    """The admin's address into the same database as an app login's address."""
    return make_conninfo(admin_url, dbname=conninfo_to_dict(app_url)["dbname"])


def setup(admin_url: str, secrets: Path, directory: str = DIRECTORY) -> Path:
    if (secrets / "directory.url").exists():
        raise AdminError(f"{secrets / 'directory.url'} already exists; the directory is set up")
    harden_cluster(admin_url)
    owner, app = f"{directory}_owner", f"{directory}_app"
    password = create_database(admin_url, directory, owner, app, load(Directory.MIGRATIONS))
    url = make_conninfo(admin_url, user=app, password=password, dbname=directory)
    _write_secret(secrets / "directory.url", url)
    return secrets / "directory.url"


def add_org(admin_url: str, secrets: Path, org_id: str) -> Path:
    directory_url = _directory_url(secrets)
    target = secrets / "orgs" / f"{org_id}.url"
    if target.exists():
        raise AdminError(f"{target} already exists; {org_id} is set up")
    org = provision(admin_url, org_id, load(ORG_MIGRATIONS))
    with psycopg.connect(_as_admin(admin_url, directory_url)) as conn:
        conn.execute(
            "INSERT INTO organizations (id, database) VALUES (%s, %s)", [org_id, org.database]
        )
    url = make_conninfo(
        admin_url, user=org.app_role, password=org.app_password, dbname=org.database
    )
    _write_secret(target, url)
    return target


def migrate_all(admin_url: str, secrets: Path) -> dict[str, list[int]]:
    """Every database brought up to date, as its owner; what each one applied."""
    directory_url = _as_admin(admin_url, _directory_url(secrets))
    directory = str(conninfo_to_dict(directory_url)["dbname"])
    applied = {
        "directory": migrate(directory_url, load(Directory.MIGRATIONS), f"{directory}_owner")
    }
    with psycopg.connect(directory_url) as conn:
        organizations = conn.execute(
            "SELECT id, database FROM organizations ORDER BY id"
        ).fetchall()
    for org_id, database in organizations:
        _, owner, _ = names_for(org_id)
        url = make_conninfo(admin_url, dbname=database)
        applied[org_id] = migrate(url, load(ORG_MIGRATIONS), owner)
    return applied


def seed_demo(admin_url: str, secrets: Path, org_id: str = DEMO_ORG) -> None:
    """The fictional demo; safe to run again. Written as the admin, past row-level security."""
    if not (secrets / "orgs" / f"{org_id}.url").exists():
        add_org(admin_url, secrets, org_id)
    database, _, _ = names_for(org_id)
    with psycopg.connect(make_conninfo(admin_url, dbname=database)) as conn:
        for mission_id, (title, team) in DEMO.items():
            conn.execute(
                "INSERT INTO missions (id, title) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                [mission_id, title],
            )
            for user in team:
                conn.execute(
                    "INSERT INTO mission_members VALUES (%s, %s) ON CONFLICT DO NOTHING",
                    [mission_id, user],
                )


def _config(env: Mapping[str, str]) -> tuple[str, Path, str]:
    merged = read_env_file(BACKEND / ".env") | dict(env)
    try:
        admin_url = read_setting(merged, "MISSIONCOPILOT_ADMIN_URL")
    except StartupError as error:
        raise AdminError(f"{error}; locally, run scripts/make_dev_env.py") from None
    secrets = Path(merged.get("MISSIONCOPILOT_SECRETS_DIR", BACKEND / ".secrets"))
    return admin_url, secrets, merged.get("MISSIONCOPILOT_DIRECTORY_DB", DIRECTORY)


def main(argv: list[str] | None = None, env: Mapping[str, str] = os.environ) -> int:
    parser = argparse.ArgumentParser(
        prog="missioncopilot-admin", description=__doc__.split("\n")[0]
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup")
    commands.add_parser("add-org").add_argument("org_id")
    commands.add_parser("migrate")
    commands.add_parser("seed-demo")
    args = parser.parse_args(argv)
    try:
        admin_url, secrets, directory = _config(env)
        if args.command == "setup":
            print(f"OK: directory set up; its address is in {setup(admin_url, secrets, directory)}")
        elif args.command == "add-org":
            path = add_org(admin_url, secrets, args.org_id)
            print(f"OK: {args.org_id} set up; its address is in {path}")
        elif args.command == "migrate":
            for name, versions in migrate_all(admin_url, secrets).items():
                print(f"OK: {name}: applied {versions or 'nothing, up to date'}")
        else:
            seed_demo(admin_url, secrets)
            print(f"OK: demo loaded into {DEMO_ORG}")
    except (AdminError, StartupError, ValueError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
