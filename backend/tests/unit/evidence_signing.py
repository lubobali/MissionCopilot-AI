"""Builds signed evidence chains the way the phone does (docs/evidence-format.md), for tests and for
the shared v2 fixture. The server never signs evidence; only phones do.

Run: uv run --directory backend python -m tests.unit.evidence_signing   (writes the fixture)
"""

import base64
import hashlib
import json
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.evidence import GENESIS_HASH, Record, link

FIXTURE = (
    Path(__file__).resolve().parents[3] / "docs" / "api" / "fixtures" / "evidence-chain-v2.json"
)


def canonical(fields: dict) -> bytes:
    """The signed bytes: sorted keys at every level, no spaces, slashes not escaped, UTF-8."""
    return json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def signed(key: ec.EllipticCurvePrivateKey, payload: bytes) -> Record:
    return Record(payload, key.sign(payload, ec.ECDSA(hashes.SHA256())))


def item(seq: int, prev: str, **changes: object) -> dict:
    """A valid v2 payload; keyword arguments change or (with None) remove fields."""
    fields: dict = {
        "v": 2,
        "seq": seq,
        "prevHash": prev,
        "contentHash": hashlib.sha256(f"file {seq}".encode()).hexdigest(),
        "kind": "photo",
        "capturedAt": f"2026-11-12T09:4{seq}:07Z",
        "clockSource": "device",
        "location": {"latE6": 12345678, "lonE6": -23456789},
        "missionId": "kandor-roads",
    }
    fields.update(changes)
    return {name: value for name, value in fields.items() if value is not None}


def chain(key: ec.EllipticCurvePrivateKey, items: list[dict]) -> tuple[list[Record], Record]:
    """Signs each item, links it to the one before, and signs the head."""
    records: list[Record] = []
    for fields in items:
        prev = link(records[-1]) if records else GENESIS_HASH
        records.append(signed(key, canonical(fields | {"prevHash": prev})))
    last = link(records[-1]) if records else GENESIS_HASH
    head = canonical({"count": len(records), "headHash": last, "missionId": "kandor-roads"})
    return records, signed(key, head)


def public_der(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def export(key: ec.EllipticCurvePrivateKey, records: list[Record], head: Record) -> dict:
    """The phone's export shape: base64 fields, as Swift's JSONEncoder writes Data."""

    def b64(record: Record) -> dict:
        return {
            "payload": base64.b64encode(record.payload).decode(),
            "signature": base64.b64encode(record.signature).decode(),
        }

    return {
        "publicKeyDER": base64.b64encode(public_der(key)).decode(),
        "records": [b64(record) for record in records],
        "head": b64(head),
    }


def fixture_items() -> list[dict]:
    """Three items covering every kind and clock source, with and without a location."""
    return [
        item(1, GENESIS_HASH),
        item(2, GENESIS_HASH, kind="scan", clockSource="gnss", location=None),
        item(3, GENESIS_HASH, kind="audio", location={"latE6": -1000000, "lonE6": 179999999}),
    ]


if __name__ == "__main__":  # pragma: no cover - writes the committed fixture with a throwaway key
    throwaway = ec.generate_private_key(ec.SECP256R1())
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    data = export(throwaway, *chain(throwaway, fixture_items()))
    FIXTURE.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {FIXTURE}")
