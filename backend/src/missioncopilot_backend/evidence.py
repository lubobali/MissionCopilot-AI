"""Verify evidence chains signed on the phone by its Secure Enclave (ADR 0009, spike #17).

Checks the exact bytes the phone signed and never re-encodes the JSON, so Swift and Python
always agree.
Needs only the public key. Same rules as EvidenceChain.verify in the iOS EncryptionLab package.
"""

import base64
import hashlib
import json
from collections.abc import Sequence
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.signatures import is_signed_by, load_p256_public_key

GENESIS_HASH = "0" * 64


@dataclass(frozen=True)
class Record:
    payload: bytes
    signature: bytes


@dataclass(frozen=True)
class Export:
    public_key_der: bytes
    records: tuple[Record, ...]
    head: Record


@dataclass(frozen=True)
class Result:
    ok: bool
    count: int = 0
    index: int | None = None
    problem: str | None = None


def load_export(data: dict) -> Export:
    """The phone's evidence-chain.json: Swift's JSONEncoder writes bytes as base64."""

    def record(item: dict) -> Record:
        return Record(base64.b64decode(item["payload"]), base64.b64decode(item["signature"]))

    return Export(
        public_key_der=base64.b64decode(data["publicKeyDER"]),
        records=tuple(record(item) for item in data["records"]),
        head=record(data["head"]),
    )


def link(record: Record) -> str:
    """The next item's prevHash: SHA-256 over the signed bytes followed by the signature."""
    return hashlib.sha256(record.payload + record.signature).hexdigest()


def _signed_by(key: ec.EllipticCurvePublicKey, record: Record) -> bool:
    return is_signed_by(key, record.signature, record.payload)


def _load_key(public_key_der: bytes) -> ec.EllipticCurvePublicKey | None:
    return load_p256_public_key(public_key_der)


def verify_chain(records: Sequence[Record], public_key_der: bytes) -> Result:
    """Signatures, sequence numbers and links, in order. Reports the first item that breaks."""
    key = _load_key(public_key_der)
    if key is None:
        return Result(ok=False, index=0, problem="bad_signature")
    expected_prev = GENESIS_HASH
    for index, record in enumerate(records):
        if not _signed_by(key, record):
            return Result(ok=False, index=index, problem="bad_signature")
        payload = json.loads(record.payload)
        if payload["prevHash"] != expected_prev:
            return Result(ok=False, index=index, problem="wrong_prev_hash")
        if payload["seq"] != index + 1:
            return Result(ok=False, index=index, problem="wrong_seq")
        expected_prev = link(record)
    return Result(ok=True, count=len(records))


def verify_with_head(records: Sequence[Record], head: Record, public_key_der: bytes) -> Result:
    """Chain check plus the signed head, which catches a cut-off last item.

    Known limit: an older head with a chain cut back to it still passes. Only the server's record
    of the latest head (ADR 0006) catches that."""
    key = _load_key(public_key_der)
    if key is None or not _signed_by(key, head):
        return Result(ok=False, problem="head_bad_signature")
    claimed = json.loads(head.payload)
    chain = verify_chain(records, public_key_der)
    if not chain.ok:
        return chain
    if any(json.loads(record.payload)["missionId"] != claimed["missionId"] for record in records):
        return Result(ok=False, problem="head_wrong_mission")
    if claimed["count"] != len(records):
        return Result(ok=False, problem="head_count_mismatch")
    if claimed["headHash"] != (link(records[-1]) if records else GENESIS_HASH):
        return Result(ok=False, problem="head_hash_mismatch")
    return chain
