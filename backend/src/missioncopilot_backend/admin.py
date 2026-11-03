"""Operator commands (#88): set up the directory, add an organization, migrate, load the demo.

Usage (uv run --directory backend missioncopilot-admin <command>):
  setup              the directory database and its own login (once)
  add-org <org id>   an organization's database, logins and address file
  migrate            every database up to the code's migrations (the server never does this itself)
  seed-demo          the fictional Kandor organization, two missions and their teams
  make-signing-key   the server's key for packs and shred orders (once); prints its public half
  publish-demo-pack  the Kandor roads pack, built from the demo dataset, signed, as the next version

The Postgres admin address comes from MISSIONCOPILOT_ADMIN_URL (or _FILE); locally, backend/.env.
The directory database is mc_directory unless MISSIONCOPILOT_DIRECTORY_DB names another.
Addresses with passwords go into MISSIONCOPILOT_ADDRESS_DIR (default backend/.db-addresses,
gitignored): directory.url and orgs/<org id>.url, each readable by its owner only, never printed.
Start the server with MISSIONCOPILOT_DIRECTORY_URL_FILE=<dir>/directory.url and
MISSIONCOPILOT_ORG_URLS_DIR=<dir>/orgs. The signing key goes to MISSIONCOPILOT_SIGNING_KEY_FILE
(default backend/.keys/signing-key.pem, gitignored, owner-only); only its public half is printed.
"""

import argparse
import base64
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path

import psycopg
from cryptography.hazmat.primitives import serialization
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
from missioncopilot_backend.db.packs import Pack, publish_pack
from missioncopilot_backend.pack_content import pack_files
from missioncopilot_backend.pack_format import key_id
from missioncopilot_backend.server import StartupError, read_setting
from missioncopilot_backend.settings import read_env_file
from missioncopilot_backend.signing_key import SigningKeyError, load_signing_key, new_signing_key

BACKEND = Path(__file__).resolve().parents[2]
DIRECTORY = "mc_directory"
DEMO_ORG = "kandor-works"
DATASET = BACKEND.parent / "docs" / "demo" / "kandor-rural-roads.json"
ROADS = "6f1d2c3a-0000-4000-8000-000000000001"  # the dataset's mission id (the API uses UUIDs)
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
DEMO = {  # fictional: Kandor is not a real country
    ROADS: ("Kandor Rural Roads Project, Package 1", ("officer-7", "manager-1")),
    BRIDGES: ("Kandor Bridges", ("officer-8", "manager-1")),
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


def _directory_url(address_dir: Path) -> str:
    path = address_dir / "directory.url"
    if not path.exists():
        raise AdminError("no directory yet; run setup first")
    return path.read_text(encoding="utf-8").strip()


def _as_admin(admin_url: str, app_url: str) -> str:
    """The admin's address into the same database as an app login's address."""
    return make_conninfo(admin_url, dbname=conninfo_to_dict(app_url)["dbname"])


def setup(admin_url: str, address_dir: Path, directory: str = DIRECTORY) -> Path:
    if (address_dir / "directory.url").exists():
        raise AdminError(f"{address_dir / 'directory.url'} already exists; the directory is set up")
    harden_cluster(admin_url)
    owner, app = f"{directory}_owner", f"{directory}_app"
    password = create_database(admin_url, directory, owner, app, load(Directory.MIGRATIONS))
    url = make_conninfo(admin_url, user=app, password=password, dbname=directory)
    _write_secret(address_dir / "directory.url", url)
    return address_dir / "directory.url"


def add_org(admin_url: str, address_dir: Path, org_id: str) -> Path:
    directory_url = _directory_url(address_dir)
    target = address_dir / "orgs" / f"{org_id}.url"
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


def migrate_all(admin_url: str, address_dir: Path) -> dict[str, list[int]]:
    """Every database brought up to date, as its owner; what each one applied."""
    directory_url = _as_admin(admin_url, _directory_url(address_dir))
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


def seed_demo(admin_url: str, address_dir: Path, org_id: str = DEMO_ORG) -> None:
    """The fictional demo; safe to run again. Written as the admin, past row-level security."""
    if not (address_dir / "orgs" / f"{org_id}.url").exists():
        add_org(admin_url, address_dir, org_id)
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


def make_signing_key(path: Path) -> tuple[str, str]:
    """A new signing key in an owner-only file; its key id and public key (DER, base64) to pin."""
    public = new_signing_key(path)
    der = public.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return key_id(public), base64.b64encode(der).decode()


def publish_demo_pack(admin_url: str, key_path: Path, org_id: str = DEMO_ORG) -> Pack:
    """The roads mission's next pack from the demo dataset. Kandor bridges stays without one."""
    data = json.loads(DATASET.read_text(encoding="utf-8"))
    if data["mission"]["id"] != ROADS:
        raise AdminError("the demo dataset's mission is not the demo roads mission")
    database, _, _ = names_for(org_id)
    url = make_conninfo(admin_url, dbname=database)
    return publish_pack(url, org_id, ROADS, pack_files(data), load_signing_key(key_path))


def _key_path(env: Mapping[str, str]) -> Path:
    merged = read_env_file(BACKEND / ".env") | dict(env)
    default = BACKEND / ".keys" / "signing-key.pem"
    return Path(merged.get("MISSIONCOPILOT_SIGNING_KEY_FILE", default))


def _config(env: Mapping[str, str]) -> tuple[str, Path, str]:
    merged = read_env_file(BACKEND / ".env") | dict(env)
    try:
        admin_url = read_setting(merged, "MISSIONCOPILOT_ADMIN_URL")
    except StartupError as error:
        raise AdminError(f"{error}; locally, run scripts/make_dev_env.py") from None
    address_dir = Path(merged.get("MISSIONCOPILOT_ADDRESS_DIR", BACKEND / ".db-addresses"))
    return admin_url, address_dir, merged.get("MISSIONCOPILOT_DIRECTORY_DB", DIRECTORY)


def main(argv: list[str] | None = None, env: Mapping[str, str] = os.environ) -> int:
    parser = argparse.ArgumentParser(
        prog="missioncopilot-admin", description=__doc__.split("\n")[0]
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup")
    commands.add_parser("add-org").add_argument("org_id")
    commands.add_parser("migrate")
    commands.add_parser("seed-demo")
    commands.add_parser("make-signing-key")
    commands.add_parser("publish-demo-pack")
    args = parser.parse_args(argv)
    if args.command == "make-signing-key":  # needs no database
        try:
            found, public = make_signing_key(_key_path(env))
        except SigningKeyError as error:
            print(f"FAILED: {error}", file=sys.stderr)
            return 1
        der = base64.b64decode(public)
        print(f"OK: signing key {found} written to {_key_path(env)}; pin its public key: {public}")
        print(f"For the app (Local.xcconfig): MC_SERVER_KEYS = {der.hex()}")
        return 0
    try:
        admin_url, address_dir, directory = _config(env)
        if args.command == "setup":
            path = setup(admin_url, address_dir, directory)
            print(f"OK: directory set up; its address is in {path}")
        elif args.command == "add-org":
            path = add_org(admin_url, address_dir, args.org_id)
            print(f"OK: {args.org_id} set up; its address is in {path}")
        elif args.command == "migrate":
            for name, versions in migrate_all(admin_url, address_dir).items():
                print(f"OK: {name}: applied {versions or 'nothing, up to date'}")
        elif args.command == "publish-demo-pack":
            pack = publish_demo_pack(admin_url, _key_path(env))
            print(f"OK: Kandor roads pack version {pack.version} published, signed by key "
                  f"{pack.signature['keyId']}")  # fmt: skip
        else:
            seed_demo(admin_url, address_dir)
            print(f"OK: demo loaded into {DEMO_ORG}")
    except (AdminError, StartupError, SigningKeyError, ValueError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
