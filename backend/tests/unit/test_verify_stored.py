"""The report page's badge (#177, step 8.7.3): a stored report is verified again on every load. It
passes only when the key the server keeps for that phone signed exactly the stored approval bytes,
and those bytes name this mission, the stored draft, language and sentences (the same rule as at
sync, sync_checks.signed_names). A changed row, a missing key or another phone's key: not
verified."""

import dataclasses
import json

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.approval_keys import ApprovalKey, key_id
from missioncopilot_backend.db.sync import StoredReport, StoredSentence
from missioncopilot_backend.sync_batch import decode
from missioncopilot_backend.sync_checks import verify_stored
from tests.unit.sync_batches import PhoneBatch

pytestmark = pytest.mark.unit

MISSION = "6f1d2c3a-0000-4000-8000-000000000001"


def stored(phone: PhoneBatch, device: str = "device-1") -> StoredReport:
    body = phone.body()
    lines = [StoredSentence(s["id"], s["section"], s["text"], s["classification"],
                            tuple(s["factIds"])) for s in body["sentences"]]  # fmt: skip
    return StoredReport(
        body["draftId"],
        "en",
        phone.by,
        0.0,
        decode(body["approval"]["payload"]) or b"",
        decode(body["approval"]["signature"]) or b"",
        key_id(phone.approval_der),
        device,
        0.0,
        lines,
    )


def kept(phone: PhoneBatch, device: str = "device-1") -> ApprovalKey:
    return ApprovalKey(key_id(phone.approval_der), device, phone.approval_der, 0.0)


def test_the_stored_report_verifies_with_its_kept_key():
    phone = PhoneBatch(MISSION)

    assert verify_stored(stored(phone), MISSION, kept(phone))


def test_a_missing_key_or_another_phones_key_is_not_verified():
    phone = PhoneBatch(MISSION)

    assert not verify_stored(stored(phone), MISSION, None)
    assert not verify_stored(stored(phone), MISSION, kept(PhoneBatch(MISSION)))
    assert not verify_stored(stored(phone), MISSION, kept(phone, device="device-2"))
    named_another = dataclasses.replace(stored(phone), approval_key_id="b" * 64)
    assert not verify_stored(named_another, MISSION, kept(phone))


def test_another_mission_is_not_verified():
    phone = PhoneBatch(MISSION)

    assert not verify_stored(stored(phone), "6f1d2c3a-0000-4000-8000-000000000002", kept(phone))


@pytest.mark.parametrize("change", ["text", "section", "facts", "dropped", "draft", "language"])
def test_a_tampered_row_is_not_verified(change):
    phone = PhoneBatch(MISSION)
    report = stored(phone)
    first = report.sentences[0]
    if change == "text":
        lines = [dataclasses.replace(first, text="All works done."), *report.sentences[1:]]
    elif change == "section":
        lines = [dataclasses.replace(first, section="nextSteps"), *report.sentences[1:]]
    elif change == "facts":
        lines = [dataclasses.replace(first, fact_ids=("fact-2",)), *report.sentences[1:]]
    elif change == "dropped":
        lines = report.sentences[1:]
    else:
        lines = report.sentences
    report = dataclasses.replace(report, sentences=lines)
    if change == "draft":
        report = dataclasses.replace(report, draft_id="draft-2")
    if change == "language":
        report = dataclasses.replace(report, language="fr")

    assert not verify_stored(report, MISSION, kept(phone))


def test_a_tampered_payload_or_signature_is_not_verified():
    phone = PhoneBatch(MISSION)
    report = stored(phone)
    signed = json.loads(report.approval_payload) | {"approvedBy": "someone else"}
    changed = json.dumps(signed, sort_keys=True, separators=(",", ":")).encode()
    forged = ec.generate_private_key(ec.SECP256R1()).sign(changed, ec.ECDSA(hashes.SHA256()))

    assert not verify_stored(dataclasses.replace(report, approval_payload=changed), MISSION,
                             kept(phone))  # fmt: skip
    assert not verify_stored(dataclasses.replace(report, approval_signature=forged), MISSION,
                             kept(phone))  # fmt: skip
    assert not verify_stored(dataclasses.replace(report, approval_payload=b"not json"), MISSION,
                             kept(phone))  # fmt: skip
