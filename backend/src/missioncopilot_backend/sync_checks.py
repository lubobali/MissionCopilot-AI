"""The checks a sync batch must pass before anything is stored (#172, step 8.2.2; ADR 0006, ADR
0009, threats T13, T28, T80). In this order, the first problem is the answer:

1. Every signed item and the approval are readable.
2. The evidence chain is signed by this phone's key, unbroken, for this mission, and its head
   matches.
3. Nothing stored is rolled back or changed: what the server holds is the start of this chain.
4. The approval is signed by a key the server keeps for this phone (#171), and its bytes name
   exactly this mission, this draft, its language and its sentences with their facts.
5. Lineage: every sentence's facts are in the batch, once each; every fact's evidence is in this
   chain.

409 is a chain the server cannot accept as it stands; 422 is a batch that breaks a rule."""

import json
from dataclasses import dataclass
from datetime import datetime

from missioncopilot_backend.approval_keys import ApprovalKey
from missioncopilot_backend.db.sync import Stored
from missioncopilot_backend.evidence import Record, verify_with_head
from missioncopilot_backend.signatures import is_signed_by, load_p256_public_key
from missioncopilot_backend.sync_batch import SyncBatch, decode


@dataclass(frozen=True)
class Approved:
    approved_by: str
    approved_at: float


@dataclass(frozen=True)
class Refused:
    status: int
    code: str


def check(
    batch: SyncBatch,
    mission_id: str,
    device_key: bytes,
    approval: ApprovalKey | None,
    stored: Stored,
) -> Approved | Refused:
    records = [item.record() for item in batch.evidence]
    head = batch.head.record()
    payload, signature = decode(batch.approval.payload), decode(batch.approval.signature)
    if None in records or head is None or payload is None or signature is None:
        return Refused(422, "unreadable")
    chain = [record for record in records if record is not None]
    return (
        _chain(chain, head, device_key, mission_id)
        or _no_rollback(chain, stored)
        or _approval(batch, mission_id, approval, payload, signature)
        or _lineage(batch, len(chain))
        or _who_and_when(payload)
    )


def _chain(records: list[Record], head: Record, key: bytes, mission_id: str) -> Refused | None:
    result = verify_with_head(records, head, key)
    if not result.ok:
        return Refused(409, f"chain:{result.problem}")
    if json.loads(head.payload).get("missionId") != mission_id:
        return Refused(409, "chain:wrong_mission")
    return None


def _no_rollback(records: list[Record], stored: Stored) -> Refused | None:
    # also catches a stored chain longer than this one
    if records[: len(stored.records)] != stored.records:
        return Refused(409, "chain:rolled_back")
    return None


def _approval(
    batch: SyncBatch,
    mission_id: str,
    approval: ApprovalKey | None,
    payload: bytes,
    signature: bytes,
) -> Refused | None:
    if approval is None or approval.key_id != batch.approval.keyId:
        return Refused(422, "approval:unknown_key")
    key = load_p256_public_key(approval.public_key_der)
    if key is None or not is_signed_by(key, signature, payload):
        return Refused(422, "approval:bad_signature")
    try:
        signed = json.loads(payload)
    except ValueError:
        return Refused(422, "approval:not_this_report")
    sentences = [
        {"factIds": s.factIds, "section": s.section, "text": s.text} for s in batch.sentences
    ]
    expected = {"version": 1, "mission": mission_id, "draftId": batch.draftId,
                "language": batch.language, "sentences": sentences}  # fmt: skip
    if not isinstance(signed, dict) or any(signed.get(k) != v for k, v in expected.items()):
        return Refused(422, "approval:not_this_report")
    return None


def _lineage(batch: SyncBatch, count: int) -> Refused | None:
    ids = [fact.id for fact in batch.facts]
    if len(set(ids)) != len(ids):
        return Refused(422, "lineage:fact_twice")
    if any(fact_id not in ids for s in batch.sentences for fact_id in s.factIds):
        return Refused(422, "lineage:sentence_without_fact")
    if any(not 1 <= source.seq <= count for fact in batch.facts for source in fact.sources):
        return Refused(422, "lineage:fact_without_evidence")
    return None


def _who_and_when(payload: bytes) -> Approved | Refused:
    signed = json.loads(payload)
    try:
        at = datetime.strptime(signed["approvedAt"], "%Y-%m-%dT%H:%M:%S%z").timestamp()
        by = signed["approvedBy"]
    except (KeyError, TypeError, ValueError):
        return Refused(422, "approval:not_this_report")
    if not isinstance(by, str) or not by:
        return Refused(422, "approval:not_this_report")
    return Approved(approved_by=by, approved_at=at)
