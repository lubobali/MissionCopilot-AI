"""Building a mission pack manifest (#89, threat T51): it matches the API contract, its bytes are
canonical, and a pack outside the limits is never built."""

import hashlib
import json
from datetime import timedelta

import pytest
from cryptography.hazmat.primitives import serialization

from missioncopilot_backend.pack_format import (
    MAX_FILE_BYTES,
    MAX_PACK_BYTES,
    key_id,
)
from tests.unit.pack_helpers import FILES, MISSION, PACK, _manifest, _reason, key
from tests.unit.test_pack_contract import _validator

pytestmark = pytest.mark.unit
__all__ = ["key"]  # the fixture, used by name


# Building


def test_the_built_manifest_matches_the_contract(key):
    manifest = json.loads(_manifest(key))

    assert list(_validator("MissionPack").iter_errors(manifest)) == []
    assert (manifest["version"], manifest["missionId"], manifest["packId"]) == (3, MISSION, PACK)
    assert manifest["createdAt"] == "2026-11-03T12:00:00Z"
    assert manifest["expiresAt"] == "2026-12-03T12:00:00Z"


def test_every_file_is_listed_by_hash_size_and_type_in_path_order(key):
    files = json.loads(_manifest(key))["files"]

    assert [f["path"] for f in files] == sorted(FILES)
    checklist = next(f for f in files if f["path"] == "forms/road-checklist.json")
    assert checklist["size"] == len(FILES["forms/road-checklist.json"])
    assert checklist["mediaType"] == "application/json"
    assert {f["mediaType"] for f in files} == {"application/json", "text/markdown"}


def test_the_same_pack_gives_the_same_bytes_with_sorted_keys_and_no_spaces(key):
    first = _manifest(key)

    assert first == _manifest(key, files=dict(reversed(list(FILES.items()))))
    assert b" " not in first.replace(b"Package 1", b"")
    assert list(json.loads(first)) == sorted(json.loads(first))


def test_the_key_id_is_the_start_of_the_public_keys_hash(key):
    der = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    assert key_id(key.public_key()) == hashlib.sha256(der).hexdigest()[:16]


@pytest.mark.parametrize(
    ("files", "reason"),
    [
        ({}, "no_files"),
        ({f"sections/s{i}.json": b"{}" for i in range(65)}, "too_many_files"),
        ({"documents/big.pdf": b"x" * (MAX_FILE_BYTES + 1)}, "file_too_large"),
        ({f"documents/d{i}.pdf": b"x" * MAX_FILE_BYTES for i in range(3)}, "pack_too_large"),
        ({"../etc/passwd.json": b"{}"}, "bad_path"),
        ({"sections/Project.json": b"{}"}, "bad_path"),
        ({"other/project.json": b"{}"}, "bad_path"),
        ({"sections/run.sh": b"{}"}, "bad_path"),
    ],
)
def test_a_pack_outside_the_limits_is_never_built(key, files, reason):
    assert _reason(lambda: _manifest(key, files=files)) == reason


def test_the_limits_add_up():
    assert MAX_FILE_BYTES == 20 * 1024 * 1024 and MAX_PACK_BYTES == 50 * 1024 * 1024


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        ({"version": 0}, "bad_version"),
        ({"valid_for": timedelta(0)}, "bad_expiry"),
        ({"min_app_version": "latest"}, "bad_app_version"),
        ({"org_id": "Kandor Works"}, "bad_org"),
        ({"mission_id": "kandor-roads"}, "bad_mission"),
    ],
)
def test_bad_pack_details_are_never_built(key, overrides, reason):
    assert _reason(lambda: _manifest(key, **overrides)) == reason
