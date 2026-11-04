"""A piece of a pack file is read as a piece (#103 step 4.2, S2). Phones download in 1 MiB
pieces; reading the whole file (up to 20 MiB) from Postgres into the server for each piece cost
about 20x the work and memory. A range request now asks Postgres for the file's size and then for
exactly the asked bytes (substring), under the same row-level security as the whole file."""

import hashlib

import pytest

from missioncopilot_backend.db.packs import PostgresPacks
from tests.db.phone_world import DOCUMENT, ROADS

pytestmark = pytest.mark.db

MEMO = "documents/memo.md"


def _packs(world) -> PostgresPacks:
    return world.client.app.state.databases.packs_for(world.orgs[0])


def _sha(world) -> str:
    return world.file_path(MEMO).rsplit("/", 1)[1]


def test_a_range_request_never_loads_the_whole_file(world, monkeypatch):
    def whole_file(*args, **kwargs):
        raise AssertionError("a range request must not read the whole file")

    monkeypatch.setattr(PostgresPacks, "file", whole_file)

    answer = world.get("officer-7", world.file_path(MEMO), Range="bytes=10-19")

    assert answer.status_code == 206
    assert answer.content == DOCUMENT[10:20]


def test_size_and_piece_come_straight_from_postgres(world):
    packs, sha = _packs(world), _sha(world)

    assert packs.file_size("officer-7", ROADS, sha) == len(DOCUMENT)
    assert packs.file_piece("officer-7", ROADS, sha, 0, 5) == DOCUMENT[:5]
    assert packs.file_piece("officer-7", ROADS, sha, 100, 15) == DOCUMENT[100:115]
    assert packs.file_piece("officer-7", ROADS, sha, len(DOCUMENT) - 1, 1) == DOCUMENT[-1:]


def test_pieces_follow_the_same_row_level_security(world):
    packs, sha = _packs(world), _sha(world)

    # officer-8 is not on the roads team: no size, no piece, exactly like the whole file.
    assert packs.file_size("officer-8", ROADS, sha) is None
    assert packs.file_piece("officer-8", ROADS, sha, 0, 5) is None
    assert packs.file("officer-8", ROADS, sha) is None


def test_an_unknown_file_has_no_size(world):
    unknown = hashlib.sha256(b"not in any pack").hexdigest()

    assert _packs(world).file_size("officer-7", ROADS, unknown) is None


def test_the_whole_file_still_comes_whole(world):
    answer = world.get("officer-7", world.file_path(MEMO))

    assert answer.status_code == 200 and answer.content == DOCUMENT


def test_the_whole_file_its_size_and_a_piece_share_one_access_rule():
    from missioncopilot_backend.db import packs

    rules = {query.split(" FROM pack_files ", 1)[1] for query in (
        packs.FILE_WHOLE, packs.FILE_SIZE, packs.FILE_PIECE)}  # fmt: skip

    assert len(rules) == 1


@pytest.mark.parametrize(("method", "asked"), [("file_piece", "bytes=0-9"), ("file", None)])
def test_access_ending_between_the_two_reads_is_a_404(world, monkeypatch, method, asked):
    # The size was read, then the phone's user left the team: the bytes come back as None.
    monkeypatch.setattr(PostgresPacks, method, lambda *args, **kwargs: None)
    headers = {"Range": asked} if asked else {}

    answer = world.get("officer-7", world.file_path(MEMO), **headers)

    assert answer.status_code == 404
