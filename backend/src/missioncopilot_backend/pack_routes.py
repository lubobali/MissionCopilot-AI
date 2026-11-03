"""Mission pack downloads for the phone (API contract getPackManifest, getPackSignature,
getPackFile, threat T51, #89). Every route needs a device signature; the organization and user come
from the enrolled phone, never from the request. Postgres row-level security decides what that user
may see, so another team's mission, another organization's, a missing one and a malformed id all
get the same 404.

A file can be fetched in parts: one byte range (Range: bytes=a-b, a-, or -n for the last n bytes),
and If-Range with the ETag the phone saw. A range outside the file gets 416; a header that is not
one plain range is ignored and the whole file is sent, as HTTP says. Nothing is cached on the way:
the security headers send no-store on every answer.

The manifest and its signature are two calls. If a new version is published between them the
signature will not match, and the phone fetches both again (#91)."""

import hashlib
import re

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from missioncopilot_backend.auth import audit
from missioncopilot_backend.db.packs import Pack, PostgresPacks
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.errors import problem
from missioncopilot_backend.pack_format import SHA256, UUID

RANGE = re.compile(r"^bytes=([0-9]*)-([0-9]*)$")
NOT_FOUND = HTTPException(404)

router: APIRouter = device_router()


def _packs(request: Request, device: DevicePrincipal) -> PostgresPacks:
    databases = getattr(request.app.state, "databases", None)
    packs_for = getattr(databases, "packs_for", None)
    packs = packs_for(device.org_id) if packs_for else None
    if packs is None:
        raise NOT_FOUND
    return packs


def _newest(request: Request, device: DevicePrincipal, mission_id: str) -> Pack:
    if not UUID.match(mission_id):
        raise NOT_FOUND
    pack = _packs(request, device).newest(device.user_id, mission_id)
    if pack is None:
        raise NOT_FOUND
    return pack


def _etag(data: bytes) -> str:
    return f'"{hashlib.sha256(data).hexdigest()}"'


@router.get("/missions/{missionId}/pack/manifest")
def get_pack_manifest(
    missionId: str, request: Request, device: DevicePrincipal = Depends(require_device)
) -> Response:
    pack = _newest(request, device, missionId)
    audit(request, "pack_downloaded", org_id=device.org_id, actor=device.user_id,
          subject=f"{missionId} v{pack.version}")  # fmt: skip
    headers = {"ETag": _etag(pack.manifest)}
    return Response(pack.manifest, media_type="application/json", headers=headers)


@router.get("/missions/{missionId}/pack/signature")
def get_pack_signature(
    missionId: str, request: Request, device: DevicePrincipal = Depends(require_device)
) -> JSONResponse:
    return JSONResponse(_newest(request, device, missionId).signature)


class Unsatisfiable(Exception):
    """The range asks for bytes the file does not have: 416."""


def _range(header: str | None, size: int) -> tuple[int, int] | None:
    """(first, last) byte to send, or None for the whole file; Unsatisfiable for a 416."""
    match = RANGE.match(header or "")
    if not match or match.groups() == ("", ""):
        return None
    first, last = match.groups()
    if not first:  # the last n bytes
        n = int(last)
        if n == 0 or size == 0:
            raise Unsatisfiable
        return max(size - n, 0), size - 1
    start, end = int(first), int(last) if last else size - 1
    if last and end < start:
        return None
    if start >= size:
        raise Unsatisfiable
    return start, min(end, size - 1)


@router.get("/missions/{missionId}/pack/files/{sha256}")
def get_pack_file(
    missionId: str,
    sha256: str,
    request: Request,
    device: DevicePrincipal = Depends(require_device),
) -> Response:
    if not UUID.match(missionId) or not SHA256.match(sha256):
        raise NOT_FOUND
    data = _packs(request, device).file(device.user_id, missionId, sha256)
    if data is None:
        raise NOT_FOUND
    etag = f'"{sha256}"'
    headers = {"ETag": etag, "Accept-Ranges": "bytes"}
    if_range = request.headers.get("If-Range")
    if if_range is not None and if_range != etag:
        wanted = None  # the phone holds part of another file: send all of this one
    else:
        try:
            wanted = _range(request.headers.get("Range"), len(data))
        except Unsatisfiable:
            response = problem(416, "The range is outside the file.")
            response.headers["Content-Range"] = f"bytes */{len(data)}"
            return response
    if wanted is None:
        return Response(data, media_type="application/octet-stream", headers=headers)
    first, last = wanted
    headers["Content-Range"] = f"bytes {first}-{last}/{len(data)}"
    return Response(
        data[first : last + 1], status_code=206, media_type="application/octet-stream",
        headers=headers,
    )  # fmt: skip


def pack_routes() -> list[APIRouter]:
    return [router]
