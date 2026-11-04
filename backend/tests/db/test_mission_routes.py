"""A phone lists its own missions (#92): the caller's team missions only, in the phone's own
organization, each with its newest pack (version, created, expires) or none, so the phone can show
"Not downloaded", "Ready" and "Expires soon" before any download. The organization and the user come
from the enrolled phone, never from the request; Postgres row-level security decides the rest."""

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from missioncopilot_backend.db.packs import publish_pack
from tests.db.phone_world import BRIDGES, FILES, ROADS
from tests.db.postgres import admin_url

pytestmark = pytest.mark.db

MISSIONS = "/v1/missions"


def _org_db(world, index: int = 0) -> str:
    with psycopg.connect(world.directory_url) as conn:
        row = conn.execute(
            "SELECT database FROM organizations WHERE id = %s", [world.orgs[index]]
        ).fetchone()
    assert row is not None
    return make_conninfo(admin_url(), dbname=row[0])


def test_a_phone_sees_its_team_missions_with_the_newest_pack(world):
    answer = world.get("officer-7", MISSIONS)

    assert answer.status_code == 200
    body = answer.json()
    assert body["orgId"] == world.orgs[0]
    [roads] = body["missions"]
    assert roads["id"] == ROADS and roads["title"] == "Roads"
    assert set(roads["pack"]) == {"version", "createdAt", "expiresAt"}
    assert roads["pack"]["version"] == 1


def test_a_mission_with_no_pack_yet_says_so(world):
    [bridges] = world.get("officer-8", MISSIONS).json()["missions"]

    assert bridges == {"id": BRIDGES, "title": "Bridges", "pack": None}


def test_each_mission_gets_its_own_pack_when_one_phone_is_on_two_teams(world):
    # The demo's case: one officer on both Kandor teams, a pack for roads only.
    with psycopg.connect(_org_db(world)) as conn:
        conn.execute("INSERT INTO mission_members VALUES (%s, 'officer-7')", [BRIDGES])

    missions = world.get("officer-7", MISSIONS).json()["missions"]

    assert [(m["id"], m["pack"] and m["pack"]["version"]) for m in missions] == [
        (ROADS, 1),
        (BRIDGES, None),
    ]


def test_another_team_and_another_organization_are_never_listed(world):
    mine = world.get("officer-7", MISSIONS).json()
    elsewhere = world.get("other-org", MISSIONS).json()  # "officer-7" too, in the other org

    assert BRIDGES not in [m["id"] for m in mine["missions"]]
    assert elsewhere["orgId"] == world.orgs[1]
    assert [m["pack"] for m in elsewhere["missions"]] == [None]  # its own roads, never org A's pack


def test_the_newest_version_is_listed_after_a_new_publish(world):
    publish_pack(_org_db(world), world.orgs[0], ROADS, FILES, world.signing_key)

    [roads] = world.get("officer-7", MISSIONS).json()["missions"]

    assert roads["pack"]["version"] == 2


def test_a_pending_phone_is_refused_and_a_revoked_one_gets_its_shred_order(world):
    assert world.get("pending", MISSIONS).status_code == 401
    revoked = world.get("revoked", MISSIONS)
    assert revoked.status_code == 410
    assert revoked.json()["order"]["deviceId"] == world.phones["revoked"].id


def test_an_unsigned_request_is_refused(world):
    assert world.client.get(MISSIONS).status_code == 401


def test_the_list_is_never_cached(world):
    assert world.get("officer-7", MISSIONS).headers["cache-control"] == "no-store"
