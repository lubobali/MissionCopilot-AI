"""Operator commands (#88): set up the directory with its own login, add an organization, migrate,
load the demo; secrets land in owner-only files and are never printed. The end-to-end test starts
the real server from exactly what these commands wrote."""

import hashlib
import json
import stat
import uuid
from collections.abc import Generator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend import admin
from missioncopilot_backend.db.organizations import drop_database, drop_organization, names_for
from missioncopilot_backend.pack_content import pack_files
from missioncopilot_backend.pack_format import key_id, verify_pack
from missioncopilot_backend.server import build
from missioncopilot_backend.signing_key import load_signing_key
from tests.db.postgres import admin_url
from tests.unit.clients import local_client

pytestmark = pytest.mark.db

NOW = datetime.now(UTC)


@dataclass
class Ops:
    secrets: Path
    directory: str
    orgs: list[str]

    def org(self) -> str:
        org_id = f"t-{uuid.uuid4().hex[:12]}"
        self.orgs.append(org_id)
        return org_id


@pytest.fixture
def ops(tmp_path) -> Generator[Ops]:
    directory = f"mc_dir_{uuid.uuid4().hex[:12]}"
    found = Ops(tmp_path / "secrets", directory, [])  # never the real demo org: cleanup drops these
    try:
        yield found
    finally:
        for org_id in found.orgs:
            drop_organization(admin_url(), org_id)
        drop_database(admin_url(), directory, f"{directory}_owner", f"{directory}_app")


def _server_env(ops: Ops) -> dict[str, str]:
    key = ops.secrets.parent / "keys" / "signing-key.pem"
    if not key.exists():
        admin.make_signing_key(key)
    return {
        "MISSIONCOPILOT_ENV": "test",
        "MISSIONCOPILOT_DIRECTORY_URL_FILE": str(ops.secrets / "directory.url"),
        "MISSIONCOPILOT_ORG_URLS_DIR": str(ops.secrets / "orgs"),
        "MISSIONCOPILOT_SIGNING_KEY_FILE": str(key),
    }


def _owner_only(path: Path) -> bool:
    return stat.S_IMODE(path.stat().st_mode) == 0o600


def test_setup_gives_the_directory_its_own_login_not_the_admin(ops):
    path = admin.setup(admin_url(), ops.secrets, ops.directory)

    assert _owner_only(path)
    assert stat.S_IMODE(ops.secrets.stat().st_mode) == 0o700
    with psycopg.connect(path.read_text().strip()) as conn:
        row = conn.execute(
            "SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user"
        ).fetchone()
    assert row == (f"{ops.directory}_app", False)


def test_setup_twice_is_refused(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)

    with pytest.raises(admin.AdminError, match="already"):
        admin.setup(admin_url(), ops.secrets, ops.directory)


def test_adding_an_organization_before_setup_is_refused(ops):
    with pytest.raises(admin.AdminError, match="setup first"):
        admin.add_org(admin_url(), ops.secrets, ops.org())


def test_an_organization_gets_an_owner_only_address_and_a_directory_entry(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    org_id = ops.org()

    path = admin.add_org(admin_url(), ops.secrets, org_id)

    assert path == ops.secrets / "orgs" / f"{org_id}.url" and _owner_only(path)
    with psycopg.connect(make_conninfo(admin_url(), dbname=ops.directory)) as conn:
        assert conn.execute("SELECT id FROM organizations").fetchall() == [(org_id,)]
    with pytest.raises(admin.AdminError, match="already"):
        admin.add_org(admin_url(), ops.secrets, org_id)


def test_migrate_brings_everything_up_to_date_and_says_so(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    org_id = ops.org()
    admin.add_org(admin_url(), ops.secrets, org_id)

    assert admin.migrate_all(admin_url(), ops.secrets) == {"directory": [], org_id: []}


def test_the_demo_starts_a_real_server_where_each_officer_sees_only_their_team_missions(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    demo = ops.org()
    admin.seed_demo(admin_url(), ops.secrets, demo)
    admin.seed_demo(admin_url(), ops.secrets, demo)  # safe to run again

    app = build(_server_env(ops))
    with local_client(app):
        store = app.state.databases.for_org(demo)
        assert [m.id for m in store.for_user("officer-7")] == [admin.ROADS, admin.BRIDGES]
        assert [m.id for m in store.for_user("officer-8")] == [admin.BRIDGES]
        assert [m.id for m in store.for_user("manager-1")] == [admin.ROADS, admin.BRIDGES]


def test_the_command_line_never_prints_a_password(ops, capsys):
    env = {
        "MISSIONCOPILOT_ADMIN_URL": admin_url(),
        "MISSIONCOPILOT_ADDRESS_DIR": str(ops.secrets),
        "MISSIONCOPILOT_DIRECTORY_DB": ops.directory,  # never the real one: cleanup drops it
    }
    org_id = ops.org()

    assert admin.main(["setup"], env) == 0
    assert admin.main(["add-org", org_id], env) == 0
    assert admin.main(["migrate"], env) == 0

    printed = capsys.readouterr()
    passwords = [
        conninfo_to_dict(p.read_text().strip())["password"] for p in ops.secrets.rglob("*.url")
    ]
    assert len(passwords) == 2
    assert not any(str(p) in printed.out + printed.err for p in passwords)


def test_a_failing_command_says_why_and_exits_non_zero(ops, capsys):
    env = {
        "MISSIONCOPILOT_ADMIN_URL": admin_url(),
        "MISSIONCOPILOT_ADDRESS_DIR": str(ops.secrets),
        "MISSIONCOPILOT_DIRECTORY_DB": ops.directory,  # never the real one: cleanup drops it
    }

    assert admin.main(["migrate"], env) == 1
    assert "setup first" in capsys.readouterr().err


def test_make_signing_key_prints_only_the_public_half(tmp_path, capsys):
    path = tmp_path / "keys" / "signing-key.pem"

    assert admin.main(["make-signing-key"], {"MISSIONCOPILOT_SIGNING_KEY_FILE": str(path)}) == 0

    out = capsys.readouterr().out
    assert "PRIVATE" not in out and path.read_bytes().decode().splitlines()[1] not in out
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    key = load_signing_key(path)
    assert key_id(key.public_key()) in out


def test_make_signing_key_never_overwrites(tmp_path, capsys):
    env = {"MISSIONCOPILOT_SIGNING_KEY_FILE": str(tmp_path / "signing-key.pem")}
    admin.main(["make-signing-key"], env)

    assert admin.main(["make-signing-key"], env) == 1
    assert "already exists" in capsys.readouterr().err


def test_the_demo_pack_is_published_signed_and_counts_up(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    demo = ops.org()
    admin.seed_demo(admin_url(), ops.secrets, demo)
    key = ops.secrets.parent / "keys" / "signing-key.pem"
    admin.make_signing_key(key)

    first = admin.publish_demo_pack(admin_url(), key, demo)
    second = admin.publish_demo_pack(admin_url(), key, demo)

    public = load_signing_key(key).public_key()
    manifest = verify_pack(second.manifest, second.signature, {key_id(public): public}, now=NOW)
    assert (first.version, second.version) == (1, 2)
    assert manifest["missionId"] == admin.ROADS and len(manifest["files"]) == 12


def test_the_demo_pack_is_published_with_an_admins_checklist(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    demo = ops.org()
    admin.seed_demo(admin_url(), ops.secrets, demo)
    key = ops.secrets.parent / "keys" / "signing-key.pem"
    admin.make_signing_key(key)
    form = json.loads(
        pack_files(json.loads(admin.DATASET.read_text()))["forms/road-checklist.json"]
    )
    form["settings"]["version"] = "2026110399"

    pack = admin.publish_demo_pack(admin_url(), key, demo, checklist=form)

    listed = {f["path"]: f for f in json.loads(pack.manifest)["files"]}["forms/road-checklist.json"]
    body = (json.dumps(form, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
    assert listed["sha256"] == hashlib.sha256(body).hexdigest()


def test_the_demo_can_go_into_another_organization_from_the_command_line(ops, capsys):
    # Staging keeps a second organization for the phone's end to end, so the demo there can be
    # used up without touching the real demo organization.
    env = {
        "MISSIONCOPILOT_ADMIN_URL": admin_url(),
        "MISSIONCOPILOT_ADDRESS_DIR": str(ops.secrets),
        "MISSIONCOPILOT_DIRECTORY_DB": ops.directory,
        "MISSIONCOPILOT_SIGNING_KEY_FILE": str(ops.secrets.parent / "keys" / "signing-key.pem"),
    }
    e2e, untouched = ops.org(), ops.org()
    assert admin.main(["setup"], env) == 0
    assert admin.main(["add-org", untouched], env) == 0
    assert admin.main(["make-signing-key"], env) == 0

    assert admin.main(["seed-demo", "--org", e2e], env) == 0
    assert admin.main(["publish-demo-pack", "--org", e2e], env) == 0

    out = capsys.readouterr().out
    assert f"OK: demo loaded into {e2e}" in out and f"published into {e2e}" in out
    for org_id, expected in ((e2e, (2, 1)), (untouched, (0, 0))):  # (missions, packs)
        database = make_conninfo(admin_url(), dbname=names_for(org_id)[0])
        with psycopg.connect(database) as conn:
            found = conn.execute(
                "SELECT (SELECT count(*) FROM missions), (SELECT count(*) FROM packs)"
            )
            assert found.fetchone() == expected
