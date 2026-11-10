"""Routes for device enrollment, as in the API contract (tag: devices)."""

import base64
import binascii
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from missioncopilot_backend.approval_keys import ApprovalKeyStore, KeyTaken
from missioncopilot_backend.auth import Principal, audit, require_role, secured_router
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import CodeStore, Device, DeviceStore, enroll
from missioncopilot_backend.models import StrictModel
from missioncopilot_backend.signatures import load_p256_public_key


class EnrollmentCodeRequest(StrictModel):
    userId: str = Field(min_length=1, max_length=128)
    deviceLabel: str = Field(min_length=1, max_length=80)


class EnrollmentCode(BaseModel):
    code: str
    expiresAt: str


class DeviceEnrollment(StrictModel):
    code: str = Field(min_length=1, max_length=64)
    publicKeyDER: str = Field(min_length=1, max_length=400)
    proof: str = Field(min_length=1, max_length=200)


class DeviceOut(BaseModel):
    id: str
    userId: str
    label: str
    status: str
    enrolledAt: str

    @classmethod
    def of(cls, device: Device) -> "DeviceOut":
        return cls(
            id=device.id,
            userId=device.user_id,
            label=device.label,
            status=device.status,
            enrolledAt=_iso(device.enrolled_at),
        )


class ApprovalKeyIn(StrictModel):
    publicKeyDER: str = Field(min_length=1, max_length=400)


class ApprovalKeyOut(BaseModel):
    keyId: str
    addedAt: str


ENROLLMENT_FAILED = HTTPException(401)


def _bytes(text: str) -> bytes | None:
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return None


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# Included by create_app. enroll is public: its one-time code authenticates it.
public = APIRouter(prefix="/v1")
router = secured_router()
phone = device_router()  # a device signature is the default on these


@public.post("/devices/enroll", status_code=201)
def enroll_device(body: DeviceEnrollment, request: Request) -> DeviceOut:
    """Authenticated by the one-time code, not a token; every failure is the same 401."""
    state = request.app.state
    key, proof = _bytes(body.publicKeyDER), _bytes(body.proof)
    device = None
    if key is not None and proof is not None:
        device = enroll(state.enrollment_codes, state.devices, body.code, key, proof)
    if device is None:  # one path for every failure: recorded, same answer
        audit(request, "enrollment_failed")
        raise ENROLLMENT_FAILED
    audit(request, "device_enrolled", org_id=device.org_id, actor=device.user_id)
    return DeviceOut.of(device)


@router.post("/devices/enrollment-codes", status_code=201)
def issue_enrollment_code(
    body: EnrollmentCodeRequest,
    request: Request,
    admin: Principal = Depends(require_role("admin")),
) -> EnrollmentCode:
    codes: CodeStore = request.app.state.enrollment_codes
    code, grant = codes.issue(admin.org_id, body.userId, body.deviceLabel)
    audit(request, "enrollment_code_issued", org_id=admin.org_id, actor=admin.user_id)
    return EnrollmentCode(code=code, expiresAt=_iso(grant.expires_at))


@router.get("/devices")
def list_devices(
    request: Request, manager: Principal = Depends(require_role("manager", "admin"))
) -> list[DeviceOut]:
    devices: DeviceStore = request.app.state.devices
    return [DeviceOut.of(device) for device in devices.of_org(manager.org_id)]


@router.post("/devices/{deviceId}/approve")
def approve_device(
    deviceId: str, request: Request, manager: Principal = Depends(require_role("manager"))
) -> DeviceOut:
    devices: DeviceStore = request.app.state.devices
    device = devices.in_org(manager.org_id, deviceId)
    if device is None:
        raise HTTPException(404)
    if device.user_id == manager.user_id:  # separation of duties: never your own phone
        audit(request, "role_denied", org_id=manager.org_id, actor=manager.user_id)
        raise HTTPException(403)
    if device.status != "pending":  # a revoked phone stays revoked
        raise HTTPException(409)
    device = devices.update(device, status="active")
    audit(request, "device_approved", manager.org_id, manager.user_id, subject=device.id)
    return DeviceOut.of(device)


@router.post("/devices/{deviceId}/revoke")
def revoke_device(
    deviceId: str,
    request: Request,
    manager: Principal = Depends(require_role("manager", "admin")),
) -> DeviceOut:
    devices: DeviceStore = request.app.state.devices
    device = devices.in_org(manager.org_id, deviceId)
    if device is None:
        raise HTTPException(404)
    device = devices.update(device, status="revoked")
    audit(request, "device_revoked", manager.org_id, manager.user_id, subject=device.id)
    return DeviceOut.of(device)


@phone.get("/devices/me")
def get_own_device(
    request: Request, caller: DevicePrincipal = Depends(require_device)
) -> DeviceOut:
    """The calling phone's own record: a pending phone never gets here (401), so a 200 means
    approved. A phone only ever sees itself."""
    devices: DeviceStore = request.app.state.devices
    device = devices.find(caller.device_id)
    if device is None:  # removed between the signature check and now
        raise HTTPException(401)
    return DeviceOut.of(device)


@phone.post("/devices/me/approval-key", status_code=201)
def add_approval_key(
    body: ApprovalKeyIn,
    request: Request,
    response: Response,
    caller: DevicePrincipal = Depends(require_device),
) -> ApprovalKeyOut:
    """The phone's Face ID approval key (#171): kept with this phone so a sync can check its
    approvals. P-256 only, never the phone's own request key (one key, one job); the same key again
    answers the same record (200); another phone's key is refused (409)."""
    key = _bytes(body.publicKeyDER)
    devices: DeviceStore = request.app.state.devices
    device = devices.find(caller.device_id)
    usable = key is not None and load_p256_public_key(key) is not None
    if not usable or device is None or key == device.public_key_der:
        raise HTTPException(422)
    keys: ApprovalKeyStore = request.app.state.approval_keys
    known = len(keys.keys_of(caller.device_id))
    try:
        kept = keys.add(caller.device_id, key)
    except KeyTaken:
        raise HTTPException(409) from None
    if len(keys.keys_of(caller.device_id)) == known:
        response.status_code = 200  # already kept: safe to send again
    else:
        audit(request, "approval_key_added", caller.org_id, caller.user_id, subject=kept.key_id)
    return ApprovalKeyOut(keyId=kept.key_id, addedAt=_iso(kept.added_at))


def device_routes() -> list[APIRouter]:
    return [public, router, phone]
