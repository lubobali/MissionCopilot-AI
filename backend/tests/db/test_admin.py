"""Operator commands (#88): set up the directory with its own login, add an organization, migrate,
load the demo; secrets land in owner-only files and are never printed. The end-to-end test starts
the real server from exactly what these commands wrote."""

import stat
import uuid
from collections.abc import Generator
from dataclasses import dataclass
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from missioncopilot_backend import admin
from missioncopilot_backend.db.organizations import drop_database, drop_organization
from missioncopilot_backend.server import build
from tests.db.postgres import admin_url
from tests.unit.clients import local_client

pytestmark = pytest.mark.db


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
    return {
        "MISSIONCOPILOT_ENV": "test",
        "MISSIONCOPILOT_DIRECTORY_URL_FILE": str(ops.secrets / "directory.url"),
        "MISSIONCOPILOT_ORG_URLS_DIR": str(ops.secrets / "orgs"),
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


def test_the_demo_starts_a_real_server_where_each_officer_sees_their_own_mission(ops):
    admin.setup(admin_url(), ops.secrets, ops.directory)
    demo = ops.org()
    admin.seed_demo(admin_url(), ops.secrets, demo)
    admin.seed_demo(admin_url(), ops.secrets, demo)  # safe to run again

    app = build(_server_env(ops))
    with local_client(app):
        store = app.state.databases.for_org(demo)
        assert [m.id for m in store.for_user("officer-7")] == ["kandor-roads"]
        assert [m.id for m in store.for_user("officer-8")] == ["kandor-bridges"]
        assert [m.id for m in store.for_user("manager-1")] == ["kandor-bridges", "kandor-roads"]


def test_the_command_line_never_prints_a_password(ops, capsys):
    env = {
        "MISSIONCOPILOT_ADMIN_URL": admin_url(),
        "MISSIONCOPILOT_SECRETS_DIR": str(ops.secrets),
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
        "MISSIONCOPILOT_SECRETS_DIR": str(ops.secrets),
        "MISSIONCOPILOT_DIRECTORY_DB": ops.directory,  # never the real one: cleanup drops it
    }

    assert admin.main(["migrate"], env) == 1
    assert "setup first" in capsys.readouterr().err
