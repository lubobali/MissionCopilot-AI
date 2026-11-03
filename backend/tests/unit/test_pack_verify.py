"""Checking a mission pack as the phone will (#89, threat T51): a changed byte, a foreign key, an
expired pack, a file that is not what the manifest says, and every manifest the contract refuses are
all refused."""

import base64
import json
from datetime import timedelta

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.pack_format import (
    MAX_FILE_BYTES,
    PACK_DOMAIN,
    check_file,
    check_manifest,
    key_id,
    sign_manifest,
    verify_pack,
)
from missioncopilot_backend.shred_order import shred_message
from tests.unit.pack_helpers import FILES, NOW, _keys, _manifest, _reason, key
from tests.unit.test_pack_contract import BAD, GOOD

pytestmark = pytest.mark.unit
__all__ = ["key"]  # the fixture, used by name


# Checking, as the phone will


def test_a_signed_pack_verifies(key):
    manifest = _manifest(key)

    checked = verify_pack(manifest, sign_manifest(manifest, key), _keys(key), now=NOW)

    assert checked["version"] == 3 and len(checked["files"]) == 3


def test_the_signature_covers_the_label_and_the_exact_bytes(key):
    manifest = _manifest(key)
    signature = sign_manifest(manifest, key)

    raw = base64.b64decode(signature["signature"])
    key.public_key().verify(raw, PACK_DOMAIN + manifest, ec.ECDSA(hashes.SHA256()))
    assert signature["keyId"] == key_id(key.public_key())
    assert signature["algorithm"] == "ecdsa-p256-sha256"


@pytest.mark.parametrize("position", [0, 50, -2])
def test_one_changed_byte_in_the_manifest_is_refused(key, position):
    manifest = bytearray(_manifest(key))
    signature = sign_manifest(bytes(manifest), key)
    manifest[position] ^= 0x01

    assert _reason(lambda: verify_pack(bytes(manifest), signature, _keys(key), now=NOW)) == (
        "bad_signature"
    )


def test_a_shred_order_signature_never_passes_as_a_pack(key):
    manifest = _manifest(key)
    order = key.sign(shred_message("device-1", 1_800_000_000), ec.ECDSA(hashes.SHA256()))
    bare = key.sign(manifest, ec.ECDSA(hashes.SHA256()))  # the manifest without the pack label

    for raw in (order, bare):
        forged = sign_manifest(manifest, key) | {"signature": base64.b64encode(raw).decode()}
        assert _reason(
            lambda forged=forged: verify_pack(manifest, forged, _keys(key), now=NOW)
        ) == ("bad_signature")


def test_a_pack_signed_by_another_key_is_refused(key):
    other = ec.generate_private_key(ec.SECP256R1())
    manifest = _manifest(other)

    assert _reason(
        lambda: verify_pack(manifest, sign_manifest(manifest, other), _keys(key), now=NOW)
    ) == ("unknown_key")


def test_a_signature_claiming_the_pinned_keys_id_but_made_by_another_is_refused(key):
    other = ec.generate_private_key(ec.SECP256R1())
    manifest = _manifest(key)  # names the pinned key's id
    forged = sign_manifest(manifest, other) | {"keyId": key_id(key.public_key())}

    assert _reason(lambda: verify_pack(manifest, forged, _keys(key), now=NOW)) == "bad_signature"


def test_the_signature_must_name_the_same_key_as_the_manifest(key):
    second = ec.generate_private_key(ec.SECP256R1())
    manifest = _manifest(key)  # names the first key
    signature = sign_manifest(manifest, second)
    keys = _keys(key) | _keys(second)

    assert _reason(lambda: verify_pack(manifest, signature, keys, now=NOW)) == "key_mismatch"


@pytest.mark.parametrize("signature", ["not base64!", "", "AAAA"])
def test_a_garbled_signature_is_refused(key, signature):
    manifest = _manifest(key)
    bad = sign_manifest(manifest, key) | {"signature": signature}

    assert _reason(lambda: verify_pack(manifest, bad, _keys(key), now=NOW)) == "bad_signature"


def test_an_expired_pack_is_refused_even_when_genuine(key):
    manifest = _manifest(key)
    signature = sign_manifest(manifest, key)
    later = NOW + timedelta(days=30)

    assert _reason(lambda: verify_pack(manifest, signature, _keys(key), now=later)) == "expired"
    assert verify_pack(manifest, signature, _keys(key), now=later - timedelta(seconds=1))


def test_a_genuinely_signed_manifest_that_breaks_the_rules_is_still_refused(key):
    # A signature proves who wrote it, not that it is safe: the rules are checked after it too.
    manifest = json.dumps(GOOD | {"keyId": key_id(key.public_key()), "extra": 1}).encode()

    assert _reason(
        lambda: verify_pack(manifest, sign_manifest(manifest, key), _keys(key), now=NOW)
    ) == ("malformed")


@pytest.mark.parametrize("bad", BAD)
def test_the_code_refuses_everything_the_contract_refuses(bad):
    assert _reason(lambda: check_manifest(bad)) == "malformed"


def test_the_code_accepts_what_the_contract_accepts():
    assert check_manifest(GOOD) == GOOD


def test_not_json_is_malformed(key):
    manifest = b"\xff not json"

    assert _reason(
        lambda: verify_pack(manifest, sign_manifest(manifest, key), _keys(key), now=NOW)
    ) == ("malformed")


# Each file against its manifest entry


def test_a_file_that_matches_its_entry_passes(key):
    entry = json.loads(_manifest(key))["files"][0]

    check_file(entry, FILES[entry["path"]])


def test_a_file_of_the_wrong_size_or_content_is_refused(key):
    entry = json.loads(_manifest(key))["files"][0]
    data = FILES[entry["path"]]

    assert _reason(lambda: check_file(entry, data + b" ")) == "wrong_size"
    assert _reason(lambda: check_file(entry, bytes([data[0] ^ 1]) + data[1:])) == "wrong_hash"


def test_a_signature_naming_another_algorithm_is_refused(key):
    manifest = _manifest(key)
    other = sign_manifest(manifest, key) | {"algorithm": "rsa-sha1"}

    assert _reason(lambda: verify_pack(manifest, other, _keys(key), now=NOW)) == "bad_signature"


def test_exactly_64_files_is_allowed(key):
    files = {f"sections/s{i}.json": b"{}" for i in range(64)}

    assert len(json.loads(_manifest(key, files=files))["files"]) == 64


@pytest.mark.parametrize("field", ["version", "formatVersion"])
def test_true_is_not_a_number(field):
    assert _reason(lambda: check_manifest(GOOD | {field: True})) == "malformed"


def test_a_bad_key_id_is_never_built(key):
    assert _reason(lambda: _manifest(key, key_id="x")) == "bad_key"


def test_a_manifest_whose_files_add_up_to_more_than_50_mb_is_refused():
    big = {"sha256": "a" * 64, "size": MAX_FILE_BYTES, "mediaType": "application/pdf"}
    files = [big | {"path": f"documents/d{i}.pdf"} for i in range(3)]  # each fine, 60 MB together

    assert _reason(lambda: check_manifest(GOOD | {"files": files})) == "malformed"
