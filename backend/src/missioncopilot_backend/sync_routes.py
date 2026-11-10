"""POST /v1/missions/{missionId}/sync (#172, step 8.2.3; ADR 0006): a team member's phone sends the
officer's approved report. The server runs every check (sync_checks.py) before storing anything,
stores the batch in one transaction, and answers with a receipt. The same Idempotency-Key, or the
same approved draft under a new key (a retry after a lost answer), answers the first receipt: safe
to send again."""

import hashlib
import uuid
from datetime import UTC, datetime

import psycopg
from fastapi import Depends, Header, HTTPException, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from missioncopilot_backend.approval_keys import ApprovalKeyStore
from missioncopilot_backend.auth import audit
from missioncopilot_backend.db.sync import PostgresSync, Receipt
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import DeviceStore
from missioncopilot_backend.errors import problem
from missioncopilot_backend.pack_format import UUID
from missioncopilot_backend.sync_batch import SyncBatch
from missioncopilot_backend.sync_checks import Refused, check

router = device_router()
NOT_FOUND = HTTPException(404)


class SyncReceipt(BaseModel):
    batchId: str
    receivedAt: str
    itemCount: int
    alreadyApplied: bool

    @classmethod
    def of(cls, receipt: Receipt, again: bool) -> "SyncReceipt":
        at = datetime.fromtimestamp(receipt.received_at, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        return cls(batchId=receipt.batch_id, receivedAt=at, itemCount=receipt.item_count,
                   alreadyApplied=again)  # fmt: skip


def _sync_store(request: Request, device: DevicePrincipal, mission_id: str) -> PostgresSync:
    """This organization's store, only for a mission on the caller's team: anything else is 404."""
    databases = getattr(request.app.state, "databases", None)
    missions = databases.for_org(device.org_id) if databases else None
    sync_for = getattr(databases, "sync_for", None)
    store = sync_for(device.org_id) if sync_for else None
    if (
        not UUID.match(mission_id)
        or missions is None
        or store is None
        or missions.get(device.user_id, mission_id) is None
    ):
        raise NOT_FOUND
    return store


def _key(text: str) -> str:
    try:
        return str(uuid.UUID(text))
    except ValueError:
        raise HTTPException(422, "Idempotency-Key must be a UUID") from None


@router.post("/missions/{missionId}/sync", status_code=201, response_model=SyncReceipt)
def sync_mission(
    missionId: str,
    body: SyncBatch,
    request: Request,
    response: Response,
    idempotency_key: str = Header(alias="Idempotency-Key"),
    device: DevicePrincipal = Depends(require_device),
) -> SyncReceipt | JSONResponse:
    key = _key(idempotency_key)
    store = _sync_store(request, device, missionId)
    user = device.user_id
    earlier = store.receipt(user, missionId, key=key) or store.receipt(
        user, missionId, draft_id=body.draftId
    )
    if earlier is not None:
        response.status_code = 200
        return SyncReceipt.of(earlier, again=True)
    devices: DeviceStore = request.app.state.devices
    phone = devices.find(device.device_id)
    if phone is None:
        raise HTTPException(401)
    keys: ApprovalKeyStore = request.app.state.approval_keys
    approval = keys.find(device.device_id, body.approval.keyId)
    result = check(body, missionId, phone.public_key_der, approval, store.stored(user, missionId))
    # A refusal says its reason, so the phone can say it in words; it reveals nothing secret.
    if isinstance(result, Refused):
        return problem(result.status, result.code)
    try:
        receipt = store.save(user, missionId, body, device_id=device.device_id,
                             approved_by=result.approved_by, approved_at=result.approved_at,
                             key=key, now=devices.now())  # fmt: skip
    except psycopg.errors.UniqueViolation:  # the same batch raced in: answer the one that won
        won = store.receipt(user, missionId, draft_id=body.draftId)
        if won is None:
            raise HTTPException(409, "report:already_received") from None
        response.status_code = 200
        return SyncReceipt.of(won, again=True)
    audit(request, "mission_synced", device.org_id, user, subject=missionId)
    return SyncReceipt.of(receipt, again=False)


class EvidenceFile(BaseModel):
    seq: int
    sha256: str


@router.post(
    "/missions/{missionId}/evidence/{seq}/file", status_code=201, response_model=EvidenceFile
)
async def add_evidence_file(
    missionId: str,
    seq: int,
    request: Request,
    response: Response,
    device: DevicePrincipal = Depends(require_device),
) -> EvidenceFile | JSONResponse:
    """The file behind a received evidence item (#172, 8.2.4): kept only when its SHA-256 is the
    contentHash the phone signed. The same file again answers 200."""
    data = await request.body()
    store = await run_in_threadpool(_sync_store, request, device, missionId)
    signed = await run_in_threadpool(store.content_hash, device.user_id, missionId, seq)
    if signed is None:
        raise NOT_FOUND
    if hashlib.sha256(data).hexdigest() != signed:
        return problem(422, "file:not_the_signed_one")
    devices: DeviceStore = request.app.state.devices
    if not await run_in_threadpool(
        store.add_file, device.user_id, missionId, seq, data, devices.now()
    ):
        response.status_code = 200
    return EvidenceFile(seq=seq, sha256=signed)


def sync_routes() -> list:
    return [router]
