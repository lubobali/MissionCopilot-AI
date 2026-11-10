"""The dashboard's pages for one mission (#176, #177): the project page, the report page, the files
a report's proof shows, and the way in from the portfolio. Every page needs a manager's session,
else sign-in (a file: 401); another organization's mission or an unknown one is 404."""

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse, Response

from missioncopilot_backend.approval_keys import ApprovalKeyStore
from missioncopilot_backend.dashboard_auth import DashboardUser
from missioncopilot_backend.dashboard_layout import reader, shell
from missioncopilot_backend.dashboard_project_page import render as render_project
from missioncopilot_backend.dashboard_proof import CONFIDENTIAL_ROLE, sniff
from missioncopilot_backend.dashboard_report_page import render as render_report
from missioncopilot_backend.dashboard_routes import COOKIE, site
from missioncopilot_backend.sync_checks import verify_stored

router = APIRouter(prefix="/dashboard/missions", dependencies=[Depends(site)])
SIGN_IN = "/dashboard/sign-in"


def signed_in(request: Request) -> DashboardUser | None:
    token = request.cookies.get(COOKIE)
    return request.app.state.dashboard.session(token) if token else None


def palette_for(title: str, mission_id: str) -> list[tuple[str, str, str]]:
    base = f"/dashboard/missions/{mission_id}"
    return [("All missions", "Page", "/dashboard"),
            (f"{title}: report", "Page", f"{base}/report"),
            (f"{title}: project", "Page", f"{base}/project")]  # fmt: skip


@router.get("/{missionId}", response_model=None)
def mission(missionId: str, request: Request) -> Response:
    """From the portfolio: the report when one waits (#177), else the project page."""
    user = signed_in(request)
    if user is None:
        return RedirectResponse(SIGN_IN, status_code=303)
    waits = reader(request, user.org_id).report(user.user_id, missionId) is not None
    page = "report" if waits else "project"
    return RedirectResponse(f"/dashboard/missions/{missionId}/{page}", status_code=303)


@router.get("/{missionId}/project", response_model=None)
def project(missionId: str, request: Request) -> Response:
    user = signed_in(request)
    if user is None:
        return RedirectResponse(SIGN_IN, status_code=303)
    view = reader(request, user.org_id).project(user.user_id, missionId)
    if view is None:
        raise HTTPException(404)
    return shell(
        view.row.title, user.name, render_project(view), palette_for(view.row.title, missionId)
    )


@router.get("/{missionId}/report", response_model=None)
def report(missionId: str, request: Request) -> Response:
    user = signed_in(request)
    if user is None:
        return RedirectResponse(SIGN_IN, status_code=303)
    view = reader(request, user.org_id).report(user.user_id, missionId)
    if view is None:
        raise HTTPException(404)
    keys: ApprovalKeyStore = request.app.state.approval_keys
    key = keys.find(view.stored.device_id, view.stored.approval_key_id)
    verified = verify_stored(view.stored, missionId, key)  # again on every load (8.7.3)
    body = render_report(view, user.roles, verified)
    title = f"{view.row.title}: aide-memoire"
    return shell(title, user.name, body, palette_for(view.row.title, missionId), ("report",))


@router.get("/{missionId}/evidence/{seq}", response_model=None)
def evidence(missionId: str, seq: int, request: Request) -> Response:
    """A file the report's proof shows: never cached (headers.py), its type from its bytes."""
    user = signed_in(request)
    if user is None:
        raise HTTPException(401)
    kept = reader(request, user.org_id).evidence_file(user.user_id, missionId, seq)
    kind = sniff(kept.data) if kept else None
    if (
        kept is None
        or kind is None
        or (kept.confidential_only and CONFIDENTIAL_ROLE not in user.roles)
    ):
        raise HTTPException(404)
    return Response(kept.data, media_type=kind)  # headers.py: no-store, nosniff
