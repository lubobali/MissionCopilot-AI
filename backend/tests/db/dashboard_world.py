"""An organization with a published pack and a synced report, for the dashboard's reads (#175):
the Kandor pack's project, financing and ratings sections, a report with a raised red flag, and a
finished walk whose file holds the sample point."""

import hashlib
import json
import uuid
from collections.abc import Generator
from dataclasses import dataclass
from pathlib import Path

import psycopg
from cryptography.hazmat.primitives.asymmetric import ec
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS
from missioncopilot_backend.db.organizations import drop_organization, provision
from missioncopilot_backend.db.packs import publish_pack
from missioncopilot_backend.db.sync import PostgresSync
from missioncopilot_backend.evidence import GENESIS_HASH, Record, link
from missioncopilot_backend.sync_batch import SyncBatch
from tests.db.postgres import admin_url
from tests.unit.evidence_signing import canonical, item, signed
from tests.unit.sync_batches import PhoneBatch, signed_item

ROADS = "6f1d2c3a-0000-4000-8000-000000000001"
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
FIXTURE = Path(__file__).resolve().parents[3] / "docs" / "api" / "fixtures" / "pack-v2-kandor"
WALK = {
    "answers": {"bridge_started": "no", "sample_point": "41.859881 -87.713197 184.4 6.8"},
    "checks": {}, "finishedAt": 1794200000, "formId": "road-checklist", "formVersion": "3",
}  # fmt: skip


def kandor_files() -> dict[str, bytes]:
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    return {f["path"]: (FIXTURE / "files" / f["sha256"]).read_bytes() for f in manifest["files"]}


@dataclass
class DashboardWorld:
    pool: ConnectionPool
    admin: str
    org_id: str


def report_batch(phone: PhoneBatch) -> tuple[SyncBatch, bytes]:
    """The phone's batch with a walk item (its file holds the sample point) and a red flag fact."""
    walk = canonical(WALK)
    records: list[Record] = []
    for seq in range(1, 4):
        prev = link(records[-1]) if records else GENESIS_HASH
        changes = {"kind": "walk", "contentHash": hashlib.sha256(walk).hexdigest()}
        fields = item(seq, prev, missionId=phone.mission, **(changes if seq == 2 else {}))
        records.append(signed(phone.device_key, canonical(fields)))
    head = {"count": 3, "headHash": link(records[-1]), "missionId": phone.mission}
    body = phone.body()
    body["evidence"] = [signed_item(r) for r in records]
    body["head"] = signed_item(signed(phone.device_key, canonical(head)))
    body["facts"][0] = body["facts"][0] | {"ruleId": "red-flag", "name": "flag:MC-01:0",
                                           "classification": "strictly_confidential"}  # fmt: skip
    return SyncBatch.model_validate(body), walk


def dashboard_world(sync: bool = True) -> Generator[DashboardWorld]:
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    created = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    admin = make_conninfo(admin_url(), dbname=created.database)
    with psycopg.connect(admin) as conn:
        conn.execute("INSERT INTO missions (id, title) VALUES (%s, 'Roads'), (%s, 'Bridges')",
                     [ROADS, BRIDGES])  # fmt: skip
        conn.execute("INSERT INTO mission_members VALUES (%s, 'officer-7'), (%s, 'officer-8')",
                     [ROADS, BRIDGES])  # fmt: skip
    publish_pack(admin, org_id, ROADS, kandor_files(), ec.generate_private_key(ec.SECP256R1()))
    app = make_conninfo(
        admin_url(), user=created.app_role, password=created.app_password, dbname=created.database
    )
    try:
        with ConnectionPool(app, min_size=1, max_size=2, open=True) as pool:
            if sync:
                batch, walk = report_batch(PhoneBatch(ROADS))
                store = PostgresSync(pool)
                store.save("officer-7", ROADS, batch, device_id=str(uuid.uuid4()),
                           approved_by="this-phone", approved_at=1_794_268_800.0,
                           key=str(uuid.uuid4()), now=1_794_270_000.0)  # fmt: skip
                store.add_file("officer-7", ROADS, 2, walk, 1_794_270_001.0)
            yield DashboardWorld(pool, admin, org_id)
    finally:
        drop_organization(admin_url(), org_id)
