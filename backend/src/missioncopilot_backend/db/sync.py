"""Synced reports in an organization's own database (#172, step 8.2.1), read and written as one user
so Postgres row-level security keeps every row to the mission's team
(sql/organization/0003_sync.sql). A batch is written in one transaction: all of it, or nothing. The
checks run before (sync_checks.py)."""

import json
import uuid
from dataclasses import dataclass
from typing import LiteralString

from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.session import as_user
from missioncopilot_backend.evidence import Record
from missioncopilot_backend.sync_batch import SyncBatch, decode


@dataclass(frozen=True)
class Receipt:
    batch_id: str
    received_at: float
    item_count: int
    already_applied: bool = False


@dataclass(frozen=True)
class Stored:
    """The mission's evidence as received, in order, and the newest head."""

    records: list[Record]
    head: Record | None


@dataclass(frozen=True)
class StoredSentence:
    sentence_id: str
    section: str
    text: str
    classification: str
    fact_ids: tuple[str, ...]


@dataclass(frozen=True)
class StoredReport:
    draft_id: str
    language: str
    approved_by: str
    approved_at: float
    approval_payload: bytes
    approval_signature: bytes
    approval_key_id: str
    device_id: str
    received_at: float
    sentences: list[StoredSentence]


class PostgresSync:
    def __init__(self, pool: ConnectionPool):
        self._pool = pool

    def stored(self, user_id: str, mission_id: str) -> Stored:
        with as_user(self._pool, user_id) as conn:
            rows = conn.execute(
                "SELECT payload, signature FROM evidence WHERE mission_id = %s ORDER BY seq",
                [mission_id],
            ).fetchall()
            head = conn.execute(
                "SELECT payload, signature FROM evidence_heads WHERE mission_id = %s"
                " ORDER BY count DESC LIMIT 1",
                [mission_id],
            ).fetchone()
        return Stored(
            [Record(bytes(p), bytes(s)) for p, s in rows],
            Record(bytes(head[0]), bytes(head[1])) if head else None,
        )

    def receipt(
        self, user_id: str, mission_id: str, key: str | None = None, draft_id: str | None = None
    ) -> Receipt | None:
        """The receipt of an earlier batch: by its idempotency key, or by the draft it brought."""
        if key is not None:
            query: LiteralString = (
                "SELECT batch_id, received_at, item_count FROM sync_receipts"
                " WHERE mission_id = %s AND idempotency_key::text = %s"
            )
            value = key
        else:
            query = (
                "SELECT batch_id, received_at, item_count FROM sync_receipts"
                " WHERE mission_id = %s AND draft_id = %s"
            )
            value = draft_id
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(query, [mission_id, value]).fetchone()
        return Receipt(str(row[0]), row[1], row[2]) if row else None

    def report(self, user_id: str, mission_id: str) -> StoredReport | None:
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT draft_id, language, approved_by, approved_at, approval_payload,"
                " approval_signature, approval_key_id, device_id, received_at FROM reports"
                " WHERE mission_id = %s",
                [mission_id],
            ).fetchone()
            if row is None:
                return None
            lines = conn.execute(
                "SELECT sentence_id, section, text, classification, fact_ids FROM report_sentences"
                " WHERE mission_id = %s ORDER BY position",
                [mission_id],
            ).fetchall()
        draft, language, by, at, payload, signature, key, device, received = row
        sentences = [StoredSentence(i, sec, t, c, tuple(f)) for i, sec, t, c, f in lines]
        return StoredReport(draft, language, by, at, bytes(payload), bytes(signature), key,
                            str(device), received, sentences)  # fmt: skip

    def save(
        self,
        user_id: str,
        mission_id: str,
        batch: SyncBatch,
        *,
        device_id: str,
        approved_by: str,
        approved_at: float,
        key: str,
        now: float,
    ) -> Receipt:
        """Writes the new evidence (after what is stored), the head, the facts not yet kept, the
        report, and the receipt, in one transaction."""
        records = [item.record() for item in batch.evidence]
        head = batch.head.record()
        approval = (decode(batch.approval.payload), decode(batch.approval.signature))
        if any(r is None for r in records) or head is None or None in approval:
            raise ValueError("unreadable base64: check the batch first")
        with as_user(self._pool, user_id) as conn:
            known = conn.execute(
                "SELECT count(*) FROM evidence WHERE mission_id = %s", [mission_id]
            ).fetchone()
            new = [r for r in records[known[0] if known else 0 :] if r is not None]
            for record in new:
                fields = json.loads(record.payload)
                conn.execute(
                    "INSERT INTO evidence VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    [mission_id, fields["seq"], record.payload, record.signature, fields["kind"],
                     fields["contentHash"], now],
                )  # fmt: skip
            conn.execute(
                "INSERT INTO evidence_heads VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
                [mission_id, len(records), head.payload, head.signature, now],
            )
            facts = 0
            for fact in batch.facts:
                added = conn.execute(
                    "INSERT INTO facts VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
                    " ON CONFLICT DO NOTHING RETURNING id",
                    [mission_id, fact.id, fact.name, fact.value, fact.unit, fact.ruleId,
                     fact.ruleVersion, fact.classification],
                ).fetchone()  # fmt: skip
                if added is None:
                    continue
                facts += 1
                for source in fact.sources:
                    conn.execute(
                        "INSERT INTO fact_sources VALUES (%s, %s, %s, %s)",
                        [mission_id, fact.id, source.seq, source.region],
                    )
            conn.execute(
                "INSERT INTO reports VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                [mission_id, batch.draftId, batch.language, approved_by, approved_at, approval[0],
                 approval[1], batch.approval.keyId, uuid.UUID(device_id), now],
            )  # fmt: skip
            for position, sentence in enumerate(batch.sentences):
                conn.execute(
                    "INSERT INTO report_sentences VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    [mission_id, position, sentence.id, sentence.section, sentence.text,
                     sentence.classification, sentence.factIds],
                )  # fmt: skip
            receipt = Receipt(str(uuid.uuid4()), now, len(new) + facts + len(batch.sentences))
            conn.execute(
                "INSERT INTO sync_receipts VALUES (%s, %s, %s, %s, %s, %s)",
                [uuid.UUID(key), mission_id, uuid.UUID(receipt.batch_id), batch.draftId,
                 receipt.item_count, now],
            )  # fmt: skip
        return receipt

    def content_hash(self, user_id: str, mission_id: str, seq: int) -> str | None:
        """The SHA-256 the phone signed for this item, if the item was received (#172, 8.2.4)."""
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT content_hash FROM evidence WHERE mission_id = %s AND seq = %s",
                [mission_id, seq],
            ).fetchone()
        return row[0] if row else None

    def add_file(self, user_id: str, mission_id: str, seq: int, data: bytes, now: float) -> bool:
        """Keeps the file; False when it was kept before. Check its hash first (content_hash)."""
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "INSERT INTO evidence_files VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING"
                " RETURNING seq",
                [mission_id, seq, data, now],
            ).fetchone()
        return row is not None

    def file(self, user_id: str, mission_id: str, seq: int) -> bytes | None:
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT data FROM evidence_files WHERE mission_id = %s AND seq = %s",
                [mission_id, seq],
            ).fetchone()
        return bytes(row[0]) if row else None
