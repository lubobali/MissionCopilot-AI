"""The dashboard's pages for one mission (#176, #177): the project page, and the way in from the
portfolio. Every page needs a manager's session, else sign-in; another organization's mission or an
unknown one is 404."""

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse, Response

from missioncopilot_backend.dashboard_auth import DashboardUser
from missioncopilot_backend.dashboard_layout import reader, shell
from missioncopilot_backend.dashboard_project_page import render as render_project
from missioncopilot_backend.dashboard_routes import COOKIE, site

router = APIRouter(prefix="/dashboard/missions", dependencies=[Depends(site)])


def signed_in(request: Request) -> DashboardUser | None:
    token = request.cookies.get(COOKIE)
    return request.app.state.dashboard.session(token) if token else None


def palette_for(title: str, mission_id: str) -> list[tuple[str, str, str]]:
    return [("All missions", "Page", "/dashboard"),
            (f"{title}: project", "Page", f"/dashboard/missions/{mission_id}/project")]  # fmt: skip


@router.get("/{missionId}", response_model=None)
def mission(missionId: str, request: Request) -> Response:
    """From the portfolio: the report when one waits (#177), else the project page."""
    if signed_in(request) is None:
        return RedirectResponse("/dashboard/sign-in", status_code=303)
    return RedirectResponse(f"/dashboard/missions/{missionId}/project", status_code=303)


@router.get("/{missionId}/project", response_model=None)
def project(missionId: str, request: Request) -> Response:
    user = signed_in(request)
    if user is None:
        return RedirectResponse("/dashboard/sign-in", status_code=303)
    view = reader(request, user.org_id).project(user.user_id, missionId)
    if view is None:
        raise HTTPException(404)
    return shell(
        view.row.title, user.name, render_project(view), palette_for(view.row.title, missionId)
    )
