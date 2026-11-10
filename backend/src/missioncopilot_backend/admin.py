"""Operator commands (#88): set up the directory, add an organization, migrate, load the demo.

Usage (uv run --directory backend missioncopilot-admin <command>):
  setup              the directory database and its own login (once)
  add-org <org id>   an organization's database, logins and address file
  migrate            every database up to the code's migrations (the server never does this itself)
  seed-demo [--org ID]  the fictional Kandor demo (two missions and their teams) into kandor-works
                        or another organization
  make-signing-key   the server's key for packs and shred orders (once); prints its public half
  publish-demo-pack [--checklist FORM.xlsx] [--org ID]  the Kandor roads pack, built from the
                     demo dataset, with an admin's checklist if given, checked, signed, as the
                     next version (into kandor-works or another organization)
  convert-checklist FORM.xlsx [--out FILE]   check an .xlsx form and write the pack's checklist JSON
                                             (no database; try a form before publishing it)
  issue-code <org> <user> [--label]  a one-time code for one person's phone (15 minutes)
  list-devices <org>                 the organization's phones
  approve-device <id> --by <you>     approve a pending phone (never your own)
  revoke-device <id> --by <you>      revoke a phone: its next request gets a shred order

The Postgres admin address comes from MISSIONCOPILOT_ADMIN_URL (or _FILE); locally, backend/.env.
The directory database is mc_directory unless MISSIONCOPILOT_DIRECTORY_DB names another.
Addresses with passwords go into MISSIONCOPILOT_ADDRESS_DIR (default backend/.db-addresses,
gitignored): directory.url and orgs/<org id>.url, each readable by its owner only, never printed.
Start the server with MISSIONCOPILOT_DIRECTORY_URL_FILE=<dir>/directory.url and
MISSIONCOPILOT_ORG_URLS_DIR=<dir>/orgs. The signing key goes to MISSIONCOPILOT_SIGNING_KEY_FILE
(default backend/.keys/signing-key.pem, gitignored, owner-only); only its public half is printed.
The defaults and backend/.env apply in a repo checkout only; on a server (an installed package)
MISSIONCOPILOT_ADDRESS_DIR and MISSIONCOPILOT_SIGNING_KEY_FILE must be set (admin_config).
"""

import argparse
import base64
import json
import os
import sys
from collections.abc import Mapping
from importlib.resources import files
from pathlib import Path

import psycopg
from cryptography.hazmat.primitives import serialization
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend import admin_config, admin_dashboard, admin_devices
from missioncopilot_backend.admin_common import AdminError, as_admin, directory_url
from missioncopilot_backend.admin_config import DIRECTORY
from missioncopilot_backend.checklist_xlsx import from_xlsx
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
from missioncopilot_backend.pack_content import check_pack_files, pack_files
from missioncopilot_backend.pack_format import key_id
from missioncopilot_backend.server import StartupError
from missioncopilot_backend.signing_key import SigningKeyError, load_signing_key, new_signing_key

DEMO_ORG = "kandor-works"
DATASET = files("missioncopilot_backend") / "data" / "kandor-rural-roads.json"  # copy of docs/demo/
ROADS = "6f1d2c3a-0000-4000-8000-000000000001"  # the dataset's mission id (the API uses UUIDs)
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
DEMO = {  # fictional: Kandor is not a real country
    ROADS: ("Kandor Rural Roads Project, Package 1", ("officer-7", "manager-1")),
    BRIDGES: ("Kandor Bridges", ("officer-7", "officer-8", "manager-1")),  # #92: both on one phone
}


def _write_secret(path: Path, text: str) -> None:
    """Owner-only, and never over an existing file."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise AdminError(f"{path} already exists; not overwriting it") from None
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(text + "\n")


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
    directory = directory_url(address_dir)
    target = address_dir / "orgs" / f"{org_id}.url"
    if target.exists():
        raise AdminError(f"{target} already exists; {org_id} is set up")
    org = provision(admin_url, org_id, load(ORG_MIGRATIONS))
    with psycopg.connect(as_admin(admin_url, directory)) as conn:
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
    url = as_admin(admin_url, directory_url(address_dir))
    directory = str(conninfo_to_dict(url)["dbname"])
    applied = {"directory": migrate(url, load(Directory.MIGRATIONS), f"{directory}_owner")}
    with psycopg.connect(url) as conn:
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


def publish_demo_pack(
    admin_url: str, key_path: Path, org_id: str = DEMO_ORG, checklist: dict | None = None
) -> Pack:
    """The roads mission's next pack from the demo dataset (with an admin's checklist if given),
    checked against the contract first. Kandor bridges stays without one."""
    data = json.loads(DATASET.read_text(encoding="utf-8"))
    if data["mission"]["id"] != ROADS:
        raise AdminError("the demo dataset's mission is not the demo roads mission")
    database, _, _ = names_for(org_id)
    url = make_conninfo(admin_url, dbname=database)
    files = pack_files(data, checklist)
    check_pack_files(files)
    return publish_pack(url, org_id, ROADS, files, load_signing_key(key_path))


DEVICE_COMMANDS = {"issue-code", "list-devices", "approve-device", "revoke-device"}


def _devices(args: argparse.Namespace, admin_url: str, address_dir: Path) -> None:
    if args.command == "issue-code":
        code, expires = admin_devices.issue_code(
            admin_url, address_dir, args.org_id, args.user_id, args.label
        )
        print(f"OK: one-time code for {args.user_id}: {code}")
        print(f"It works once, for 15 minutes (until {expires}). Give it to them in person.")
    elif args.command == "list-devices":
        for device in admin_devices.list_devices(admin_url, address_dir, args.org_id):
            print(f"{device.id}  {device.status:8}  {device.user_id}  {device.label}")
    elif args.command == "approve-device":
        device = admin_devices.approve(admin_url, address_dir, args.device_id, args.by)
        print(f"OK: {device.id} ({device.user_id}) approved")
    else:
        device = admin_devices.revoke(admin_url, address_dir, args.device_id, args.by)
        print(f"OK: {device.id} ({device.user_id}) revoked; its next request gets a shred order")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="missioncopilot-admin", description=__doc__.split("\n")[0]
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("setup", "migrate", "make-signing-key"):
        commands.add_parser(name)
    # --org: another organization than the demo one, e.g. staging's for the phone's end to end.
    commands.add_parser("seed-demo").add_argument("--org", default=DEMO_ORG)
    publish = commands.add_parser("publish-demo-pack")
    publish.add_argument("--checklist", type=Path)
    publish.add_argument("--org", default=DEMO_ORG)
    convert = commands.add_parser("convert-checklist")
    convert.add_argument("form", type=Path)
    convert.add_argument("--out", type=Path)
    commands.add_parser("add-org").add_argument("org_id")
    code = commands.add_parser("issue-code")
    code.add_argument("org_id")
    code.add_argument("user_id")
    code.add_argument("--label", default="iPhone")
    commands.add_parser("list-devices").add_argument("org_id")
    invite = commands.add_parser("invite-manager")  # #174: a one-time dashboard link
    invite.add_argument("org_id")
    invite.add_argument("user_id")
    invite.add_argument("--name", required=True)
    invite.add_argument("--base", required=True, help="the dashboard address, https://...")
    invite.add_argument("--confidential", action="store_true", help="may read red flags (#177)")
    for name in ("approve-device", "revoke-device"):
        phone = commands.add_parser(name)
        phone.add_argument("device_id")
        phone.add_argument("--by", required=True, help="your own name, for the audit log")
    return parser


def _signing_key_command(env: Mapping[str, str]) -> None:
    path = admin_config.key_path(env)
    found, public = make_signing_key(path)
    der = base64.b64decode(public)
    print(f"OK: signing key {found} written to {path}; pin its public key: {public}")
    print(f"For the app (Local.xcconfig): MC_SERVER_KEYS = {der.hex()}")


def _convert_command(form_path: Path, out: Path | None) -> None:
    form, dropped = from_xlsx(form_path)
    body = json.dumps(form, indent=2, ensure_ascii=False) + "\n"
    if out:
        out.write_text(body, encoding="utf-8")
    else:
        print(body, end="")
    french = any("::French (fr)" in key for row in form["survey"] + form["choices"] for key in row)
    rows = sum(1 for row in form["survey"] if row["type"] != "end_group")
    print(f"OK: {rows} questions and groups, {len(form['choices'])} choices, "
          f"English{' and French' if french else ''}")  # fmt: skip
    for note in dropped:
        print(f"dropped: {note}")


def _database_command(args: argparse.Namespace, env: Mapping[str, str]) -> None:
    admin_url, address_dir, directory = admin_config.settings(env)
    if args.command in DEVICE_COMMANDS:
        _devices(args, admin_url, address_dir)
    elif args.command == "invite-manager":
        link, expires = admin_dashboard.invite_manager(
            admin_url, address_dir, args.org_id, args.user_id, args.name, args.base,
            confidential=args.confidential,
        )  # fmt: skip
        print(
            f"OK: invite for {args.name}: {link}\nIt works once, for 15 minutes (until {expires})."
        )
    elif args.command == "setup":
        path = setup(admin_url, address_dir, directory)
        print(f"OK: directory set up; its address is in {path}")
    elif args.command == "add-org":
        path = add_org(admin_url, address_dir, args.org_id)
        print(f"OK: {args.org_id} set up; its address is in {path}")
    elif args.command == "migrate":
        for name, versions in migrate_all(admin_url, address_dir).items():
            print(f"OK: {name}: applied {versions or 'nothing, up to date'}")
    elif args.command == "publish-demo-pack":
        checklist = from_xlsx(args.checklist)[0] if args.checklist else None
        key = admin_config.key_path(env)
        pack = publish_demo_pack(admin_url, key, org_id=args.org, checklist=checklist)
        print(f"OK: Kandor roads pack version {pack.version} published into {args.org}, signed "
              f"by key {pack.signature['keyId']}")  # fmt: skip
    else:
        seed_demo(admin_url, address_dir, args.org)
        print(f"OK: demo loaded into {args.org}")


def main(argv: list[str] | None = None, env: Mapping[str, str] = os.environ) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "make-signing-key":  # needs no database
            _signing_key_command(env)
        elif args.command == "convert-checklist":  # needs no database either
            _convert_command(args.form, args.out)
        else:
            _database_command(args, env)
    except (AdminError, StartupError, SigningKeyError, ValueError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    except (OSError, psycopg.Error) as error:  # a file or the database: one line, no traceback
        reason = str(error).strip().splitlines()[0] if str(error).strip() else ""
        print(f"FAILED: {error.__class__.__name__}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
