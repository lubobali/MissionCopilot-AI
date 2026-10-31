"""An evidence chain signed by the iPhone's Secure Enclave (spike #17) must verify here in Python
with only the public key, and every kind of tampering must be caught (fixture: the phone export)."""

import base64
import json
from dataclasses import replace
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.evidence import Record, load_export, verify_chain, verify_with_head

pytestmark = pytest.mark.unit

RESULTS = Path(__file__).resolve().parents[3] / "docs" / "spikes" / "results"
EXPORT_PATH = RESULTS / "evidence-chain-iphone13promax.json"


@pytest.fixture(scope="module")
def phone():
    return load_export(json.loads(EXPORT_PATH.read_text(encoding="utf-8")))


def _flip_last_byte_but_two(data: bytes) -> bytes:
    changed = bytearray(data)
    changed[-3] ^= 0x01
    return bytes(changed)


def test_phone_chain_and_head_verify_with_only_the_public_key(phone):
    assert verify_with_head(phone.records, phone.head, phone.public_key_der).ok
    assert verify_with_head(phone.records, phone.head, phone.public_key_der).count == 3


def test_payloads_are_the_signed_sorted_key_json(phone):
    first = json.loads(phone.records[0].payload)
    assert list(first) == sorted(first)
    assert (first["seq"], first["missionId"]) == (1, "kandor-roads")


def test_one_changed_byte_in_item_two_is_caught(phone):
    records = list(phone.records)
    records[1] = replace(records[1], payload=_flip_last_byte_but_two(records[1].payload))

    result = verify_chain(records, phone.public_key_der)

    assert (result.ok, result.index, result.problem) == (False, 1, "bad_signature")


def test_removed_middle_item_is_caught(phone):
    records = [phone.records[0], phone.records[2]]

    result = verify_chain(records, phone.public_key_der)

    assert (result.ok, result.index, result.problem) == (False, 1, "wrong_prev_hash")


def test_cut_off_last_item_is_caught_by_the_head(phone):
    result = verify_with_head(phone.records[:2], phone.head, phone.public_key_der)

    assert (result.ok, result.problem) == (False, "head_count_mismatch")


def test_changed_head_is_caught(phone):
    head = Record(
        payload=_flip_last_byte_but_two(phone.head.payload), signature=phone.head.signature
    )

    result = verify_with_head(phone.records, head, phone.public_key_der)

    assert (result.ok, result.problem) == (False, "head_bad_signature")


def test_another_key_rejects_the_first_item(phone):
    other = (
        ec.generate_private_key(ec.SECP256R1())
        .public_key()
        .public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    )

    result = verify_chain(phone.records, other)

    assert (result.ok, result.index, result.problem) == (False, 0, "bad_signature")


def test_export_is_base64_as_swift_writes_it():
    raw = json.loads(EXPORT_PATH.read_text(encoding="utf-8"))
    assert base64.b64decode(raw["publicKeyDER"])[:2] == b"\x30\x59"  # DER SEQUENCE of a P-256 SPKI
