"""Builds a sync batch the way the phone does (#172): a signed evidence chain for one mission, facts
citing its items, an approved draft's sentences citing the facts, and the officer's approval signed
by a separate key over canonical JSON of the draft (ios ReportApproval.payload). The server never
builds these."""

import base64
import hashlib
from dataclasses import dataclass, field

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.approval_keys import key_id
from missioncopilot_backend.evidence import GENESIS_HASH, Record, link
from missioncopilot_backend.sync_batch import SyncBatch
from tests.unit.evidence_signing import canonical, item, public_der, signed


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def signed_item(record: Record) -> dict:
    return {"payload": b64(record.payload), "signature": b64(record.signature)}


def chain_for(
    key: ec.EllipticCurvePrivateKey, mission: str, count: int
) -> tuple[list[Record], Record]:
    records: list[Record] = []
    for seq in range(1, count + 1):
        prev = link(records[-1]) if records else GENESIS_HASH
        fields = item(seq, prev, missionId=mission, kind="scan" if seq % 2 else "photo")
        records.append(signed(key, canonical(fields)))
    head = {"count": len(records), "headHash": link(records[-1]), "missionId": mission}
    return records, signed(key, canonical(head))


def approval_payload(mission: str, draft: str, sentences: list[dict], by: str, at: str) -> bytes:
    lines = [
        {"factIds": s["factIds"], "section": s["section"], "text": s["text"]} for s in sentences
    ]
    return canonical({"approvedAt": at, "approvedBy": by, "draftId": draft, "language": "en",
                      "mission": mission, "sentences": lines, "version": 1})  # fmt: skip


@dataclass
class PhoneBatch:
    mission: str
    device_key: ec.EllipticCurvePrivateKey = field(
        default_factory=lambda: ec.generate_private_key(ec.SECP256R1())
    )
    approval_key: ec.EllipticCurvePrivateKey = field(
        default_factory=lambda: ec.generate_private_key(ec.SECP256R1())
    )
    count: int = 3
    draft: str = "draft-1"
    by: str = "this-phone"
    at: str = "2026-11-10T00:00:00Z"

    @property
    def approval_der(self) -> bytes:
        return public_der(self.approval_key)

    @property
    def device_der(self) -> bytes:
        return public_der(self.device_key)

    def body(self, **changes: object) -> dict:
        records, head = chain_for(self.device_key, self.mission, self.count)
        facts = [
            {"id": f"fact-{seq}", "name": "amountDue", "value": str(480000 + seq), "unit": "USD",
             "ruleId": "scan-invoice", "ruleVersion": "1", "classification": "official_use_only",
             "sources": [{"seq": seq, "region": f"page {seq}"}]}
            for seq in range(1, self.count + 1)
        ]  # fmt: skip
        sentences = [
            {"id": f"s{i}", "section": "findings", "text": f"From your scanned invoice: line {i}.",
             "classification": "official_use_only", "factIds": [f"fact-{i}"]}
            for i in range(1, self.count + 1)
        ]  # fmt: skip
        payload = approval_payload(self.mission, self.draft, sentences, self.by, self.at)
        signature = self.approval_key.sign(payload, ec.ECDSA(hashes.SHA256()))
        body = {
            "evidence": [signed_item(r) for r in records],
            "head": signed_item(head),
            "facts": facts,
            "draftId": self.draft,
            "language": "en",
            "sentences": sentences,
            "approval": {"payload": b64(payload), "signature": b64(signature),
                         "keyId": key_id(self.approval_der)},
        }  # fmt: skip
        body.update(changes)
        return body

    def batch(self, **changes: object) -> SyncBatch:
        return SyncBatch.model_validate(self.body(**changes))


def content(seq: int) -> bytes:
    """The file whose SHA-256 the signed item names (evidence_signing.item)."""
    data = f"file {seq}".encode()
    assert hashlib.sha256(data).hexdigest()  # same rule as item()
    return data
