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
from cryptography.hazmat.primitives import hashes
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
from tests.unit.sync_batches import PhoneBatch, approval_payload, b64, signed_item

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


PHOTO = b"\xff\xd8\xff\xe0 a site photo"
ACTION = "Start the Section 3 bridge works"


def resign(phone: PhoneBatch, body: dict) -> dict:
    """The approval again, over the batch's sentences as they now stand (the phone signs last)."""
    payload = approval_payload(phone.mission, phone.draft, body["sentences"], phone.by, phone.at)
    signature = phone.approval_key.sign(payload, ec.ECDSA(hashes.SHA256()))
    body["approval"] = body["approval"] | {"payload": b64(payload), "signature": b64(signature)}
    return body


def report_batch(phone: PhoneBatch) -> tuple[SyncBatch, bytes]:
    """The phone's batch: the pack (1), the finished walk (2, its file holds the sample point), a
    site photo (3). Facts: a red flag on the pack, an agreed action from the pack, and the walk's
    check of that action with its photo; one sentence each, the red flag's strictly confidential."""
    walk = canonical(WALK)
    actions = hashlib.sha256(kandor_files()["sections/agreed-actions.json"]).hexdigest()
    kinds = {1: ("pack", b"file 1"), 2: ("walk", walk), 3: ("photo", PHOTO)}
    records: list[Record] = []
    for seq in range(1, 4):
        prev = link(records[-1]) if records else GENESIS_HASH
        kind, data = kinds[seq]
        fields = item(seq, prev, missionId=phone.mission, kind=kind,
                      contentHash=hashlib.sha256(data).hexdigest())  # fmt: skip
        records.append(signed(phone.device_key, canonical(fields)))
    head = {"count": 3, "headHash": link(records[-1]), "missionId": phone.mission}
    body = phone.body()
    body["evidence"] = [signed_item(r) for r in records]
    body["head"] = signed_item(signed(phone.device_key, canonical(head)))
    facts = body["facts"]
    facts[0] |= {
        "ruleId": "red-flag",
        "name": "flag:MC-01:0",
        "value": "flag",
        "classification": "strictly_confidential",
        "sources": [{"seq": 1, "region": f"sections/contracts.json#/contracts/0 sha256:{actions}"}],
    }
    facts[1] |= {
        "ruleId": "pack-record",
        "name": "pack:sections/agreed-actions.json#/actions/0",
        "value": ACTION,
        "unit": None,
        "sources": [
            {"seq": 1, "region": f"sections/agreed-actions.json#/actions/0 sha256:{actions}"}
        ],
    }
    facts[2] |= {
        "ruleId": "walk-answer",
        "name": "walk:action-Start the Se",
        "unit": None,
        "value": "seen: no; note: no works on site",
        "sources": [{"seq": 2, "region": f"action:{ACTION}"}, {"seq": 3, "region": None}],
    }
    body["sentences"][0] |= {
        "text": "The payment ratio rule flagged contract 1.",
        "classification": "strictly_confidential",
    }
    body["sentences"][1] |= {
        "section": "agreedActions",
        "text": "Start the Section 3 bridge works.",
    }
    body["sentences"][2] |= {"section": "agreedActions", "text": "The site walk saw no works."}
    return SyncBatch.model_validate(resign(phone, body)), walk


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
                store.add_file("officer-7", ROADS, 3, PHOTO, 1_794_270_002.0)
            yield DashboardWorld(pool, admin, org_id)
    finally:
        drop_organization(admin_url(), org_id)
