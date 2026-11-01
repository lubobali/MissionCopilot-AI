"""Signed device requests (threat model T26, T27; contract scheme deviceSignature). An approved
phone signs every request with its Secure Enclave key over request_message(): method, path and
query, device id, a strictly increasing sequence number, Unix time and the SHA-256 of the body.
The sequence number makes every request usable once; the time window limits how long an
intercepted request stays usable and allows for a phone's clock drift. A refused request never
moves the sequence on, so forged requests with huge numbers cannot lock the real phone out. Every
refusal is the same 401 and is recorded."""

import base64
import binascii
import hashlib
from dataclasses import dataclass

from fastapi import APIRouter, Depends, HTTPException, Request
from starlette.datastructures import Headers

from missioncopilot_backend.auth import audit
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.signatures import is_signed_by, load_p256_public_key

REQUEST_DOMAIN = b"missioncopilot-request-v1\n"
TIME_WINDOW_SECONDS = 300
REFUSED = HTTPException(401, headers={"WWW-Authenticate": "DeviceSignature"})


def request_message(
    method: str, path: str, device_id: str, seq: int, at: int, body: bytes
) -> bytes:
    """The exact bytes the phone signs. Changing them breaks every enrolled phone."""
    fields = [method, path, device_id, str(seq), str(at), hashlib.sha256(body).hexdigest()]
    return REQUEST_DOMAIN + "\n".join(fields).encode()


@dataclass(frozen=True)
class DevicePrincipal:
    """Who is calling, from the enrolled device only."""

    device_id: str
    org_id: str
    user_id: str


def _signed_fields(headers: Headers) -> tuple[int, int, bytes] | None:
    seq, at = headers.get("X-Device-Seq", ""), headers.get("X-Device-Time", "")
    if not seq.isdigit() or not at.isdigit() or int(seq) < 1:
        return None
    try:
        signature = base64.b64decode(headers.get("X-Device-Signature", ""), validate=True)
    except (binascii.Error, ValueError):
        return None
    return (int(seq), int(at), signature) if signature else None


async def require_device(request: Request) -> DevicePrincipal:
    devices: DeviceRegistry = request.app.state.devices
    device = devices.find(request.headers.get("X-Device-Id", ""))
    fields = _signed_fields(request.headers)
    body = await request.body()  # cached: the route reads the same bytes
    if device is None or device.status != "active" or fields is None:
        return _refuse(request, device.id if device else None)
    seq, at, signature = fields
    if abs(devices.now() - at) > TIME_WINDOW_SECONDS:
        return _refuse(request, device.id)
    key = load_p256_public_key(device.public_key_der)
    query = request.url.query
    path = request.url.path + (f"?{query}" if query else "")
    message = request_message(request.method, path, device.id, seq, at, body)
    if key is None or not is_signed_by(key, signature, message):
        return _refuse(request, device.id)
    if not devices.accept_seq(device.id, seq):  # only after the signature: forgeries move nothing
        return _refuse(request, device.id)
    return DevicePrincipal(device_id=device.id, org_id=device.org_id, user_id=device.user_id)


def _refuse(request: Request, device_id: str | None) -> DevicePrincipal:
    # The subject is a known device id only: an unknown header value never reaches the log.
    audit(request, "device_auth_failed", subject=device_id)
    raise REFUSED


def device_router() -> APIRouter:
    """The router for every phone-facing route: a valid device signature is the default."""
    return APIRouter(prefix="/v1", dependencies=[Depends(require_device)])
