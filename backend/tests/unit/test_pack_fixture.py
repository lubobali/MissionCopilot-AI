"""The signed Kandor pack the app's tests use (docs/api/fixtures/pack-v2-kandor, #89): it verifies
with its public key, every file matches its manifest entry, and it is the pack the dataset builds
today (rerun scripts/make_pack_fixture.py after changing the dataset)."""

import base64
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from missioncopilot_backend.pack_content import pack_files
from missioncopilot_backend.pack_format import PackError, check_file, key_id, verify_pack
from missioncopilot_backend.signatures import load_p256_public_key

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "docs" / "api" / "fixtures" / "pack-v2-kandor"
DATA = json.loads((ROOT / "docs" / "demo" / "kandor-rural-roads.json").read_text(encoding="utf-8"))
MANIFEST = (FIXTURE / "manifest.json").read_bytes()
SIGNATURE = json.loads((FIXTURE / "signature.json").read_text(encoding="utf-8"))
PUBLIC = load_p256_public_key(base64.b64decode((FIXTURE / "public-key.der.b64").read_text()))
assert PUBLIC is not None, "the fixture's public key is not P-256"
KEYS = {key_id(PUBLIC): PUBLIC}
NOW = datetime(2026, 11, 10, tzinfo=UTC)


def test_the_fixture_verifies_with_its_public_key():
    manifest = verify_pack(MANIFEST, SIGNATURE, KEYS, now=NOW)

    assert manifest["missionId"] == DATA["mission"]["id"]
    assert manifest["orgId"] == "kandor-works" and manifest["version"] == 1


def test_every_fixture_file_matches_its_manifest_entry():
    for entry in json.loads(MANIFEST)["files"]:
        check_file(entry, (FIXTURE / "files" / entry["sha256"]).read_bytes())


def test_the_fixture_holds_nothing_but_the_listed_files():
    listed = {entry["sha256"] for entry in json.loads(MANIFEST)["files"]}

    assert {path.name for path in (FIXTURE / "files").iterdir()} == listed


def test_the_fixture_is_the_pack_the_dataset_builds_today():
    built = pack_files(DATA)
    fixture = {e["path"]: e["sha256"] for e in json.loads(MANIFEST)["files"]}

    assert set(fixture) == set(built), "rerun scripts/make_pack_fixture.py"
    for path, sha in fixture.items():
        assert (FIXTURE / "files" / sha).read_bytes() == built[path], (
            f"{path} changed: rerun scripts/make_pack_fixture.py"
        )


def test_one_changed_byte_in_the_fixture_manifest_is_refused():
    changed = bytearray(MANIFEST)
    changed[10] ^= 0x01

    with pytest.raises(PackError, match="bad_signature"):
        verify_pack(bytes(changed), SIGNATURE, KEYS, now=NOW)


def test_no_private_key_is_in_the_fixture():
    for path in FIXTURE.rglob("*"):
        if path.is_file():
            assert b"PRIVATE KEY" not in path.read_bytes(), path
