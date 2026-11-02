"""Payload v2 on the server (docs/evidence-format.md, #71). The signature already proves who signed;
these checks prove a signed item also follows the format, so a buggy or hostile phone cannot slip a
bad field in. The phone's v1 chain from spike #17 keeps verifying."""

import json

import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.evidence import (
    GENESIS_HASH,
    load_export,
    verify_chain,
    verify_with_head,
)
from tests.unit.evidence_signing import (
    FIXTURE,
    canonical,
    chain,
    fixture_items,
    item,
    public_der,
    signed,
)

pytestmark = pytest.mark.unit

KEY = ec.generate_private_key(ec.SECP256R1())


def check(*items: dict):
    return verify_chain(chain(KEY, list(items))[0], public_der(KEY))


def changed(change: dict) -> dict:
    """A valid first item with one change; None removes the field."""
    fields = item(1, GENESIS_HASH) | change
    return {name: value for name, value in fields.items() if value is not None}


def test_the_shared_v2_fixture_verifies_with_its_head():
    export = load_export(json.loads(FIXTURE.read_text(encoding="utf-8")))

    result = verify_with_head(export.records, export.head, export.public_key_der)

    assert (result.ok, result.count) == (True, 3)


def test_the_fixture_payloads_are_the_canonical_bytes():
    # The app must produce exactly these bytes from the same fields (#71 step 3).
    export = load_export(json.loads(FIXTURE.read_text(encoding="utf-8")))

    assert all(r.payload == canonical(json.loads(r.payload)) for r in export.records)
    assert [json.loads(r.payload)["kind"] for r in export.records] == ["photo", "scan", "audio"]


def test_a_valid_v2_chain_verifies():
    assert check(*fixture_items()).ok


@pytest.mark.parametrize(
    "change",
    [
        {"kind": "video"},
        {"clockSource": "ntp"},
        {"contentHash": "AB" * 32},
        {"contentHash": "ab" * 31},
        {"capturedAt": "2026-11-12T09:41:07.123Z"},
        {"capturedAt": "2026-11-12T09:41:07+00:00"},
        {"location": {"latE6": 12.5, "lonE6": 1}},
        {"location": {"latE6": 90000001, "lonE6": 0}},
        {"location": {"latE6": 0, "lonE6": -180000001}},
        {"location": {"latE6": 0, "lonE6": 0, "alt": 3}},
        {"location": {"latE6": 0}},
        {"kind": None},
        {"missionId": 7},
        {"v": 3},
        {"seq": "1"},
        {"extra": "unsigned meaning"},
    ],
)
def test_a_signed_item_that_breaks_the_format_is_refused(change):
    result = check(changed(change))

    assert (result.ok, result.index, result.problem) == (False, 0, "bad_payload")


def test_a_true_or_false_is_not_a_number():
    # In Python True == 1; JSON true must not pass as a sequence number or a coordinate.
    for change in ({"seq": True}, {"location": {"latE6": True, "lonE6": 0}}):
        assert check(changed(change)).problem == "bad_payload"


def test_without_a_version_only_the_exact_v1_shape_is_accepted():
    # A v2 item with its "v" deleted must not pass as version 1 with unchecked fields.
    assert check(changed({"v": None})).problem == "bad_payload"


def test_mixing_versions_in_one_chain_is_refused():
    v1 = {
        "seq": 2,
        "capturedAt": "2026-11-12T09:42:07Z",
        "fileSHA256": "ab" * 32,
        "missionId": "kandor-roads",
    }

    result = check(item(1, GENESIS_HASH), v1)

    assert (result.ok, result.index, result.problem) == (False, 1, "mixed_versions")


@pytest.mark.parametrize("payload", [b"not json", b"[1, 2]", b"\xff\xfe"])
def test_a_signed_item_that_is_not_a_json_object_is_refused_not_a_crash(payload):
    result = verify_chain([signed(KEY, payload)], public_der(KEY))

    assert (result.ok, result.index, result.problem) == (False, 0, "unreadable_payload")
