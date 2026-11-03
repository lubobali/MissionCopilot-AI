"""Mission packs in the organization's own database (#89, threat T51): published by an operator,
signed, read only by the mission's team, never changed, and a mission's version only goes up by
one. Files are stored once by their SHA-256, which Postgres itself checks."""

import json
import threading
import uuid
from collections.abc import Generator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import psycopg
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from psycopg import sql
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS, as_user
from missioncopilot_backend.db.organizations import drop_organization, provision
from missioncopilot_backend.db.packs import PostgresPacks, publish_pack
from missioncopilot_backend.pack_format import check_file, key_id, verify_pack
from tests.db.postgres import admin_url

pytestmark = pytest.mark.db

ROADS = "6f1d2c3a-0000-4000-8000-000000000001"
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
NOW = datetime(2026, 11, 3, 12, 0, tzinfo=UTC)
FILES = {
    "sections/project.json": b'{"title": "Kandor Rural Roads Project, Package 1"}\n',
    "documents/aide-memoire-2026-05.md": b"# Aide-memoire\n",
}


@dataclass
class Org:
    org_id: str
    admin: str  # the admin's address into the organization's database
    pool: ConnectionPool
    key: ec.EllipticCurvePrivateKey

    def publish(self, mission: str = ROADS, files: dict[str, bytes] | None = None):
        return publish_pack(
            self.admin, self.org_id, mission, FILES if files is None else files, self.key,
            created_at=NOW, valid_for=timedelta(days=30), min_app_version="0.5",
        )  # fmt: skip


@pytest.fixture
def org() -> Generator[Org]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    created = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    admin = make_conninfo(admin_url(), dbname=created.database)
    try:
        with psycopg.connect(admin) as conn:
            conn.execute(
                "INSERT INTO missions (id, title)"
                " VALUES (%s, 'Kandor roads'), (%s, 'Kandor bridges')",
                [ROADS, BRIDGES],
            )
            conn.execute(
                "INSERT INTO mission_members VALUES (%s, 'officer-7'), (%s, 'officer-8'),"
                " (%s, 'manager-1'), (%s, 'manager-1')",
                [ROADS, BRIDGES, ROADS, BRIDGES],
            )
        app = make_conninfo(
            admin_url(), user=created.app_role, password=created.app_password,
            dbname=created.database,
        )  # fmt: skip
        with ConnectionPool(app, min_size=1, max_size=2, open=True) as pool:
            yield Org(org_id, admin, pool, ec.generate_private_key(ec.SECP256R1()))
    finally:
        drop_organization(admin_url(), org_id)


def _keys(org: Org) -> dict:
    return {key_id(org.key.public_key()): org.key.public_key()}


# Publishing


def test_a_published_pack_is_signed_and_verifies(org):
    published = org.publish()

    manifest = verify_pack(published.manifest, published.signature, _keys(org), now=NOW)
    assert (published.version, manifest["version"], manifest["missionId"]) == (1, 1, ROADS)
    assert manifest["orgId"] == org.org_id


def test_each_publish_is_the_next_version(org):
    assert [org.publish().version for _ in range(3)] == [1, 2, 3]
    assert org.publish(mission=BRIDGES).version == 1  # versions count per mission


# Reading, as a member of the team


def test_a_team_member_gets_the_newest_pack_exactly_as_signed(org):
    org.publish()
    newest = org.publish(files=FILES | {"sections/ratings.json": b"{}\n"})

    pack = PostgresPacks(org.pool).newest("officer-7", ROADS)

    assert pack is not None
    assert (pack.version, pack.manifest, pack.signature) == (2, newest.manifest, newest.signature)
    assert verify_pack(pack.manifest, pack.signature, _keys(org), now=NOW)["version"] == 2


def test_another_team_or_no_pack_gives_nothing(org):
    org.publish()
    packs = PostgresPacks(org.pool)

    assert packs.newest("officer-8", ROADS) is None  # not on the roads team
    assert packs.newest("officer-8", BRIDGES) is None  # on the team, but no pack yet
    assert packs.newest("", ROADS) is None


def test_a_team_member_gets_each_file_and_it_matches_the_manifest(org):
    published = org.publish()
    packs = PostgresPacks(org.pool)

    for entry in json.loads(published.manifest)["files"]:
        data = packs.file("officer-7", ROADS, entry["sha256"])
        assert data is not None
        check_file(entry, data)


def test_a_file_is_only_served_for_a_mission_whose_pack_holds_it(org):
    roads = org.publish()
    org.publish(mission=BRIDGES, files={"sections/project.json": b'{"title": "Bridges"}\n'})
    only_roads = next(
        e["sha256"]
        for e in json.loads(roads.manifest)["files"]
        if e["path"].startswith("documents")
    )
    packs = PostgresPacks(org.pool)

    assert packs.file("manager-1", ROADS, only_roads) is not None
    assert packs.file("manager-1", BRIDGES, only_roads) is None  # on both teams: still not here
    assert packs.file("officer-8", ROADS, only_roads) is None  # not on the roads team


def test_files_of_an_older_version_stay_readable_so_a_download_can_finish(org):
    old = org.publish()
    org.publish(files={"sections/project.json": b'{"title": "v2"}\n'})
    old_doc = next(
        e["sha256"] for e in json.loads(old.manifest)["files"] if e["path"].startswith("documents")
    )

    assert (
        PostgresPacks(org.pool).file("officer-7", ROADS, old_doc)
        == FILES["documents/aide-memoire-2026-05.md"]
    )


# What the database itself refuses


@pytest.mark.parametrize("table", ["packs", "pack_contents", "pack_files"])
@pytest.mark.parametrize("change", ["UPDATE {} SET mission_id = mission_id", "DELETE FROM {}",
                                    "TRUNCATE {} CASCADE"])  # fmt: skip
def test_nothing_published_can_be_changed_even_by_an_admin(org, table, change):
    org.publish()
    statement = change.format(table)
    if table == "pack_files":
        statement = statement.replace("mission_id = mission_id", "sha256 = sha256")

    with psycopg.connect(org.admin) as conn, pytest.raises(psycopg.errors.RaiseException):
        conn.execute(statement)


def test_a_version_can_be_neither_skipped_nor_reused(org):
    published = org.publish()
    insert = (
        "INSERT INTO packs (mission_id, version, pack_id, manifest, signature, key_id, expires_at)"
        " VALUES (%s, %s, gen_random_uuid(), %s, %s, %s, now() + interval '1 day')"
    )
    fields = [published.manifest, json.dumps(published.signature), "0123456789abcdef"]

    for version in (3, 1):  # skips 2; reuses 1
        with psycopg.connect(org.admin) as conn, pytest.raises(psycopg.errors.RaiseException):
            conn.execute(insert, [ROADS, version, *fields])


def test_a_file_that_is_not_what_its_hash_says_is_refused(org):
    with psycopg.connect(org.admin) as conn, pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO pack_files (sha256, data) VALUES (%s, 'something else')", ["a" * 64]
        )


def test_the_app_login_cannot_publish(org):
    with org.pool.connection() as conn, pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute(
            "INSERT INTO pack_files (sha256, data) VALUES (encode(sha256('x'), 'hex'), 'x')"
        )


def test_two_operators_publishing_at_once_get_the_next_two_versions(org):
    results: list[int] = []
    errors: list[BaseException] = []

    def publish():
        try:
            results.append(org.publish().version)
        except BaseException as error:  # noqa: BLE001 - reported below
            errors.append(error)

    operators = [threading.Thread(target=publish) for _ in range(2)]
    for operator in operators:
        operator.start()
    for operator in operators:
        operator.join()

    assert errors == [] and sorted(results) == [1, 2]


@pytest.mark.parametrize("table", ["packs", "pack_contents", "pack_files"])
def test_a_plain_query_outside_the_team_sees_no_pack_at_all(org, table):
    # Not through PostgresPacks: the rule must hold for any query the app login could write.
    org.publish()

    count = sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))
    with as_user(org.pool, "officer-8") as conn:
        assert conn.execute(count).fetchone() == (0,)
    with as_user(org.pool, "officer-7") as conn:
        assert conn.execute(count).fetchone() != (0,)
