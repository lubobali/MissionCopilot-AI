"""Downloading a mission pack as the phone does (#89): real signed requests, a real directory and
an organization's own database. Only the mission's team gets it; another team's, another
organization's, a missing and a malformed mission all answer alike; files resume with Range and
If-Range; nothing is cached; every manifest download is in the audit log. The cross-organization
guard in test_tenancy probes token routes, so these phone routes are probed here."""

import uuid
from datetime import UTC, datetime, timedelta

import psycopg
import pytest

from missioncopilot_backend.pack_format import key_id, verify_pack
from tests.db.phone_world import BRIDGES, DOCUMENT, ROADS

pytestmark = pytest.mark.db

MANIFEST, SIGNATURE = f"/v1/missions/{ROADS}/pack/manifest", f"/v1/missions/{ROADS}/pack/signature"


def test_the_team_gets_the_manifest_exactly_as_signed_and_it_verifies(world):
    manifest = world.get("officer-7", MANIFEST)
    signature = world.get("officer-7", SIGNATURE)

    assert manifest.status_code == signature.status_code == 200
    assert manifest.content == world.manifest
    assert manifest.headers["content-type"] == "application/json"
    public = world.signing_key.public_key()
    checked = verify_pack(manifest.content, signature.json(), {key_id(public): public},
                          now=datetime.now(UTC) + timedelta(seconds=1))  # fmt: skip
    assert checked["missionId"] == ROADS


@pytest.mark.parametrize("path", [MANIFEST, SIGNATURE])
def test_pack_answers_are_never_cached(world, path):
    assert world.get("officer-7", path).headers["cache-control"] == "no-store"


def test_the_manifest_etag_is_its_hash(world):
    import hashlib

    etag = world.get("officer-7", MANIFEST).headers["etag"]

    assert etag == f'"{hashlib.sha256(world.manifest).hexdigest()}"'


@pytest.mark.parametrize(
    ("who", "mission"),
    [
        ("officer-8", ROADS),  # another team
        ("other-org", ROADS),  # another organization, same user name
        ("officer-8", BRIDGES),  # on the team, but no pack published
        ("officer-7", "6f1d2c3a-0000-4000-8000-00000000ffff"),  # no such mission
        ("officer-7", "kandor-roads"),  # not a mission id at all
    ],
)
@pytest.mark.parametrize("route", ["manifest", "signature"])
def test_everyone_else_gets_the_same_404_as_a_missing_mission(world, who, mission, route):
    missing = world.get("officer-7", f"/v1/missions/{uuid.uuid4()}/pack/{route}")
    answer = world.get(who, f"/v1/missions/{mission}/pack/{route}")

    assert answer.status_code == missing.status_code == 404
    assert answer.json() == missing.json()


def test_an_unsigned_request_gets_401_and_a_revoked_phone_its_shred_order(world):
    assert world.client.get(MANIFEST).status_code == 401
    shred = world.get("revoked", MANIFEST)

    assert shred.status_code == 410 and shred.json()["order"]["scope"] == "all-missions"


def test_every_manifest_download_is_in_the_audit_log(world):
    world.get("officer-7", MANIFEST)

    with psycopg.connect(world.directory_url) as conn:
        rows = conn.execute(
            "SELECT actor, subject FROM audit_events WHERE kind = 'pack_downloaded'"
        ).fetchall()
    assert rows == [("officer-7", f"{ROADS} v1")]


# Files


def test_a_whole_file_comes_with_its_etag_and_can_be_fetched_in_parts(world):
    answer = world.get("officer-7", world.file_path("documents/memo.md"))

    assert answer.status_code == 200 and answer.content == DOCUMENT
    assert answer.headers["accept-ranges"] == "bytes"
    assert answer.headers["cache-control"] == "no-store"
    assert answer.headers["etag"].strip('"') in world.file_path("documents/memo.md")


@pytest.mark.parametrize(
    ("asked", "first", "last"),
    [
        ("bytes=10-", 10, 114),
        ("bytes=0-9", 0, 9),
        ("bytes=-5", 110, 114),
        ("bytes=100-999", 100, 114),
    ],
)
def test_a_part_of_a_file_resumes_a_download(world, asked, first, last):
    answer = world.get("officer-7", world.file_path("documents/memo.md"), Range=asked)

    assert answer.status_code == 206
    assert answer.content == DOCUMENT[first : last + 1]
    assert answer.headers["content-range"] == f"bytes {first}-{last}/{len(DOCUMENT)}"


@pytest.mark.parametrize("asked", ["bytes=115-", "bytes=500-600", "bytes=-0"])
def test_a_range_outside_the_file_gets_416(world, asked):
    answer = world.get("officer-7", world.file_path("documents/memo.md"), Range=asked)

    assert answer.status_code == 416
    assert answer.headers["content-range"] == f"bytes */{len(DOCUMENT)}"


@pytest.mark.parametrize("asked", ["bytes=9-2", "bytes=0-1,5-6", "items=0-1", "bytes=-"])
def test_a_range_that_is_not_one_plain_range_sends_the_whole_file(world, asked):
    answer = world.get("officer-7", world.file_path("documents/memo.md"), Range=asked)

    assert answer.status_code == 200 and answer.content == DOCUMENT


def test_if_range_with_the_same_etag_resumes_and_another_sends_everything(world):
    path = world.file_path("documents/memo.md")
    etag = world.get("officer-7", path).headers["etag"]

    same = world.get("officer-7", path, Range="bytes=100-", **{"If-Range": etag})
    other = world.get("officer-7", path, Range="bytes=100-", **{"If-Range": '"' + "0" * 64 + '"'})

    assert same.status_code == 206 and same.content == DOCUMENT[100:]
    assert other.status_code == 200 and other.content == DOCUMENT


@pytest.mark.parametrize("who", ["officer-8", "other-org"])
def test_a_file_is_not_served_outside_the_team(world, who):
    assert world.get(who, world.file_path("documents/memo.md")).status_code == 404


@pytest.mark.parametrize(
    "path",
    [
        f"/v1/missions/{ROADS}/pack/files/{'0' * 64}",  # not in any pack
        f"/v1/missions/{ROADS}/pack/files/not-a-hash",
        f"/v1/missions/{BRIDGES}/pack/files/SHA",  # looked up under the wrong mission below too
    ],
)
def test_an_unknown_or_malformed_file_gets_404(world, path):
    assert world.get("officer-7", path).status_code == 404


def test_a_file_is_only_served_under_a_mission_whose_pack_holds_it(world):
    path = world.file_path("documents/memo.md", mission=BRIDGES)

    assert world.get("officer-8", path).status_code == 404
