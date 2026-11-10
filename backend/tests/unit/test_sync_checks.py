"""The sync checks (#172, step 8.2.2): a batch is stored only when the evidence chain is the phone's
and unbroken, nothing stored is rolled back or changed, the approval is signed by a key the server
keeps for that phone and names exactly this mission, draft and sentences, and every sentence traces
to facts and every fact to evidence in this chain (ADR 0009). The first problem found is the
answer."""

import json

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.approval_keys import ApprovalKey, key_id
from missioncopilot_backend.db.sync import Stored
from missioncopilot_backend.sync_batch import SyncBatch, decode
from missioncopilot_backend.sync_checks import Approved, Refused, check
from tests.unit.sync_batches import PhoneBatch, b64, chain_for

pytestmark = pytest.mark.unit

MISSION = "6f1d2c3a-0000-4000-8000-000000000001"
EMPTY = Stored([], None)


def kept(phone: PhoneBatch) -> ApprovalKey:
    return ApprovalKey(key_id(phone.approval_der), "device-1", phone.approval_der, 0.0)


def run(phone: PhoneBatch, batch: SyncBatch | None = None, stored: Stored = EMPTY, key="kept"):
    approval = kept(phone) if key == "kept" else key
    return check(batch or phone.batch(), MISSION, phone.device_der, approval, stored)


def test_a_true_batch_passes_with_who_and_when():
    phone = PhoneBatch(MISSION)

    assert run(phone) == Approved(approved_by="this-phone", approved_at=1_794_268_800.0)


def test_a_chain_signed_by_another_phone_is_refused():
    phone = PhoneBatch(MISSION)
    other, _ = chain_for(ec.generate_private_key(ec.SECP256R1()), MISSION, 3)
    body = phone.body()
    body["evidence"][1] = {"payload": b64(other[1].payload), "signature": b64(other[1].signature)}

    assert run(phone, SyncBatch.model_validate(body)) == Refused(409, "chain:bad_signature")


def test_another_missions_chain_is_refused():
    phone = PhoneBatch("6f1d2c3a-0000-4000-8000-000000000002")

    assert run(phone) == Refused(409, "chain:wrong_mission")


def test_a_rolled_back_or_changed_chain_is_refused():
    phone = PhoneBatch(MISSION, count=3)
    records = [r for r in (e.record() for e in phone.batch().evidence) if r is not None]
    longer = Stored([*records, records[0]], None)  # it had 4 items
    changed = Stored([records[1]], None)  # its first item was another one

    assert run(phone, stored=longer) == Refused(409, "chain:rolled_back")
    assert run(phone, stored=changed) == Refused(409, "chain:rolled_back")


def test_a_key_the_server_never_saw_approves_nothing():
    phone = PhoneBatch(MISSION)

    assert run(phone, key=None) == Refused(422, "approval:unknown_key")


def test_a_kept_key_that_is_not_the_one_named_approves_nothing():
    phone = PhoneBatch(MISSION)
    other = PhoneBatch(MISSION)

    assert run(phone, key=kept(other)) == Refused(422, "approval:unknown_key")


def test_an_approval_signed_by_another_key_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    forged = ec.generate_private_key(ec.SECP256R1()).sign(
        decode(body["approval"]["payload"]) or b"", ec.ECDSA(hashes.SHA256())
    )
    body["approval"]["signature"] = b64(forged)

    assert run(phone, SyncBatch.model_validate(body)) == Refused(422, "approval:bad_signature")


@pytest.mark.parametrize(
    "change",
    ["sentence text", "sentence facts", "one more sentence", "draft", "language"],
)
def test_sentences_other_than_the_approved_ones_are_refused(change):
    phone = PhoneBatch(MISSION)
    body = phone.body()
    if change == "sentence text":
        body["sentences"][0]["text"] = "From your scanned invoice: line 9."
    elif change == "sentence facts":
        body["sentences"][0]["factIds"] = ["fact-2"]
    elif change == "one more sentence":
        body["sentences"].append(body["sentences"][0] | {"id": "s9"})
    elif change == "draft":
        body["draftId"] = "draft-2"
    else:
        body["language"] = "fr"

    assert run(phone, SyncBatch.model_validate(body)) == Refused(422, "approval:not_this_report")


def test_an_approval_of_another_mission_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    payload = json.loads(decode(body["approval"]["payload"]) or b"{}")
    payload["mission"] = "6f1d2c3a-0000-4000-8000-000000000002"
    signed = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    body["approval"] = body["approval"] | {
        "payload": b64(signed),
        "signature": b64(phone.approval_key.sign(signed, ec.ECDSA(hashes.SHA256()))),
    }

    assert run(phone, SyncBatch.model_validate(body)) == Refused(422, "approval:not_this_report")


def test_a_sentence_without_its_fact_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    body["facts"] = body["facts"][1:]  # fact-1 left out, sentence s1 cites it

    assert run(phone, SyncBatch.model_validate(body)) == Refused(
        422, "lineage:sentence_without_fact"
    )


def test_a_fact_without_evidence_in_this_chain_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    body["facts"][0]["sources"] = [{"seq": 99, "region": None}]

    assert run(phone, SyncBatch.model_validate(body)) == Refused(
        422, "lineage:fact_without_evidence"
    )


def test_the_same_fact_twice_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    body["facts"].append(body["facts"][0])

    assert run(phone, SyncBatch.model_validate(body)) == Refused(422, "lineage:fact_twice")


def test_unreadable_base64_is_refused():
    phone = PhoneBatch(MISSION)
    body = phone.body()
    body["evidence"][0]["payload"] = "%%%"

    assert run(phone, SyncBatch.model_validate(body)) == Refused(422, "unreadable")
