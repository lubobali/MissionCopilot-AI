"""Resumable downloads need a strong ETag and untouched bytes (#103 step 4.3). A phone resumes with
Range plus If-Range; HTTP only allows that with a strong validator (RFC 9110 13.1.5), and anything
that changes the bytes on the way (compression) would turn the tag weak or make pieces not fit
together. So: every pack answer carries the content's SHA-256 as a strong ETag, a weak or other
tag in If-Range gets the whole file, and nothing is ever compressed, even when gzip is offered.
(nginx's side, no gzip for packs, is in the step 6 runbook.)"""

import hashlib
import re

import pytest

from missioncopilot_backend.app import create_app
from missioncopilot_backend.settings import Settings
from tests.db.phone_world import DOCUMENT

pytestmark = pytest.mark.db

MEMO = "documents/memo.md"
STRONG = re.compile(r'^"[0-9a-f]{64}"$')


def test_a_file_etag_is_its_strong_sha256(world):
    answer = world.get("officer-7", world.file_path(MEMO))

    assert STRONG.match(answer.headers["etag"])
    assert answer.headers["etag"] == f'"{hashlib.sha256(DOCUMENT).hexdigest()}"'


def test_the_manifest_etag_is_strong_too(world):
    manifest = "/v1/missions/" + world.file_path(MEMO).split("/")[3] + "/pack/manifest"
    answer = world.get("officer-7", manifest)

    assert answer.headers["etag"] == f'"{hashlib.sha256(answer.content).hexdigest()}"'


def test_if_range_with_a_weak_tag_gets_the_whole_file(world):
    path = world.file_path(MEMO)
    weak = "W/" + world.get("officer-7", path).headers["etag"]

    answer = world.get("officer-7", path, Range="bytes=100-", **{"If-Range": weak})

    assert answer.status_code == 200 and answer.content == DOCUMENT


@pytest.mark.parametrize("piece", [None, "bytes=10-19"])
def test_nothing_is_compressed_even_when_gzip_is_offered(world, piece):
    headers = {"Accept-Encoding": "gzip, br, deflate"} | ({"Range": piece} if piece else {})

    answer = world.get("officer-7", world.file_path(MEMO), **headers)

    assert "content-encoding" not in answer.headers
    assert answer.content == (DOCUMENT[10:20] if piece else DOCUMENT)


def test_the_app_has_no_compression_layer():
    layers = [str(m.cls).lower() for m in create_app(Settings()).user_middleware]

    assert [name for name in layers if "zip" in name or "compress" in name] == []
