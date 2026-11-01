"""Routes for device enrollment, as in the API contract (tag: devices)."""

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from missioncopilot_backend.auth import Principal, audit, require_role, secured_router
from missioncopilot_backend.devices import EnrollmentCodes
from missioncopilot_backend.models import StrictModel


class EnrollmentCodeRequest(StrictModel):
    userId: str = Field(min_length=1, max_length=128)
    deviceLabel: str = Field(min_length=1, max_length=80)


class EnrollmentCode(BaseModel):
    code: str
    expiresAt: str


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def device_routes() -> APIRouter:
    router = secured_router()

    @router.post("/devices/enrollment-codes", status_code=201)
    def issue_enrollment_code(
        body: EnrollmentCodeRequest,
        request: Request,
        admin: Principal = Depends(require_role("admin")),
    ) -> EnrollmentCode:
        codes: EnrollmentCodes = request.app.state.enrollment_codes
        code, grant = codes.issue(admin.org_id, body.userId, body.deviceLabel)
        audit(request, "enrollment_code_issued", org_id=admin.org_id, actor=admin.user_id)
        return EnrollmentCode(code=code, expiresAt=_iso(grant.expires_at))

    return router
