"""Synced reports in an organization's database (#172, step 8.2.1): stored in one transaction, read
back exactly, append-only, and only the mission's team may add or read them (row-level security)."""

import uuid
from collections.abc import Generator
from dataclasses import dataclass

import psycopg
import pytest
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS
from missioncopilot_backend.db.organizations import drop_organization, provision
from missioncopilot_backend.db.sync import PostgresSync
from missioncopilot_backend.sync_batch import decode
from tests.db.postgres import admin_url
from tests.unit.sync_batches import PhoneBatch

pytestmark = pytest.mark.db

ROADS = "6f1d2c3a-0000-4000-8000-000000000001"
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
DEVICE = str(uuid.uuid4())


@dataclass
class Org:
    sync: PostgresSync
    admin: str


@pytest.fixture
def org() -> Generator[Org]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    created = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    admin = make_conninfo(admin_url(), dbname=created.database)
    with psycopg.connect(admin) as conn:
        conn.execute(
            "INSERT INTO missions (id, title) VALUES (%s, 'R'), (%s, 'B')", [ROADS, BRIDGES]
        )
        conn.execute(
            "INSERT INTO mission_members VALUES (%s, 'officer-7'), (%s, 'officer-8')",
            [ROADS, BRIDGES],
        )
    app = make_conninfo(
        admin_url(), user=created.app_role, password=created.app_password, dbname=created.database
    )
    try:
        with ConnectionPool(app, min_size=1, max_size=2, open=True) as pool:
            yield Org(PostgresSync(pool), admin)
    finally:
        drop_organization(admin_url(), org_id)


def save(org: Org, batch, key: str | None = None, user: str = "officer-7", mission: str = ROADS):
    return org.sync.save(
        user, mission, batch, device_id=DEVICE, approved_by="this-phone",
        approved_at=1_794_268_800.0, key=key or str(uuid.uuid4()), now=1_794_270_000.0,
    )  # fmt: skip


def test_a_batch_is_stored_and_read_back_exactly(org):
    phone = PhoneBatch(ROADS)
    batch = phone.batch()

    receipt = save(org, batch)

    stored = org.sync.stored("officer-7", ROADS)
    sent = [e.record() for e in batch.evidence]
    assert [r.payload for r in stored.records] == [r.payload for r in sent if r is not None]
    assert stored.head == batch.head.record()
    assert receipt.item_count == 3 + 3 + 3 and not receipt.already_applied
    report = org.sync.report("officer-7", ROADS)
    assert report is not None and report.draft_id == "draft-1"
    assert [s.text for s in report.sentences] == [s.text for s in batch.sentences]
    assert report.sentences[0].fact_ids == ("fact-1",)
    assert report.approval_payload == decode(batch.approval.payload) and report.device_id == DEVICE
    assert org.sync.receipt("officer-7", ROADS, draft_id="draft-1") == receipt


def test_a_receipt_is_found_by_its_key(org):
    key = str(uuid.uuid4())
    receipt = save(org, PhoneBatch(ROADS).batch(), key=key)

    assert org.sync.receipt("officer-7", ROADS, key=key) == receipt
    assert org.sync.receipt("officer-7", ROADS, key=str(uuid.uuid4())) is None


def test_another_team_neither_reads_nor_adds(org):
    save(org, PhoneBatch(ROADS).batch())

    assert org.sync.stored("officer-8", ROADS).records == []
    assert org.sync.report("officer-8", ROADS) is None
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        save(org, PhoneBatch(ROADS).batch(), user="officer-8")


def test_nothing_is_kept_when_one_row_fails(org):
    batch = PhoneBatch(ROADS).batch()
    save(org, batch)
    second = str(uuid.uuid4())
    with psycopg.connect(org.admin) as conn:  # #178: sent back, so a next version may come
        conn.execute(
            "INSERT INTO report_reviews (mission_id, version, decision, note, reviewer_id,"
            " reviewer_name, reviewed_at, approval_hash) VALUES (%s, 1, 'sent_back', 'Again.',"
            " 'manager-1', 'Amina', 1.0, %s)",
            [ROADS, "c" * 64],
        )

    with pytest.raises(psycopg.Error):
        save(org, batch, key=second)  # the same draft id again: the whole second batch fails

    assert org.sync.receipt("officer-7", ROADS, key=second) is None, "not even its receipt"
    assert len(org.sync.stored("officer-7", ROADS).records) == 3


def test_synced_rows_never_change(org):
    save(org, PhoneBatch(ROADS).batch())

    with psycopg.connect(org.admin) as conn:
        for table in ("evidence", "facts", "reports", "report_sentences", "sync_receipts"):
            with pytest.raises(psycopg.errors.RaiseException), conn.transaction():
                conn.execute(f"DELETE FROM {table}")  # noqa: S608 - fixed table names
