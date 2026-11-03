import json

import pytest
from make_pack_fixture import write_fixture

pytestmark = pytest.mark.unit


def test_it_writes_a_manifest_a_signature_a_public_key_and_each_file(tmp_path):
    write_fixture(tmp_path / "pack")

    manifest = json.loads((tmp_path / "pack" / "manifest.json").read_bytes())
    signature = json.loads((tmp_path / "pack" / "signature.json").read_text())
    assert signature["keyId"] == manifest["keyId"]
    assert (tmp_path / "pack" / "public-key.der.b64").read_text().strip()
    names = {p.name for p in (tmp_path / "pack" / "files").iterdir()}
    assert names == {entry["sha256"] for entry in manifest["files"]}


def test_every_run_uses_a_new_throwaway_key(tmp_path):
    write_fixture(tmp_path / "a")
    write_fixture(tmp_path / "b")

    assert (tmp_path / "a" / "public-key.der.b64").read_text() != (
        tmp_path / "b" / "public-key.der.b64"
    ).read_text()


def test_an_old_fixture_is_replaced_not_mixed_in(tmp_path):
    (tmp_path / "pack" / "files").mkdir(parents=True)
    (tmp_path / "pack" / "files" / "stale").write_text("old")

    write_fixture(tmp_path / "pack")

    assert not (tmp_path / "pack" / "files" / "stale").exists()
