"""The dashboard's pages (#174, step 8.4.4; the look of #175): built on the server as plain HTML,
with this server's stylesheet, fonts and one script (WebAuthn needs the browser's
navigator.credentials). Every value written into a page is escaped. The sign-in pages need no
session; every other page does, and without one goes to sign-in."""

import mimetypes
from html import escape
from importlib.resources import files

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from missioncopilot_backend.dashboard_layout import MEDALLION, reader, shell
from missioncopilot_backend.dashboard_mission_pages import router as missions
from missioncopilot_backend.dashboard_portfolio import render as render_portfolio
from missioncopilot_backend.dashboard_routes import COOKIE, site

STATIC = files("missioncopilot_backend") / "dashboard_static"
mimetypes.add_type(
    "font/woff2", ".woff2"
)  # a slim server image has no type for it (found on staging)
PLANE = MEDALLION  # the brand, as on the iPhone (dashboard_layout)


def page(title: str, body: str, *, cover: bool = False) -> HTMLResponse:
    kind = ' class="cover"' if cover else ""
    return HTMLResponse(
        f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{escape(title)} · MissionCopilot</title>
<link rel="stylesheet" href="/dashboard/static/dashboard.css">
<script src="/dashboard/static/dashboard.js" defer></script>
</head>
<body{kind}>
<a class="skip" href="#main">Skip to content</a>
<main id="main">
{body}
</main>
</body>
</html>
"""
    )


def _card(heading: str, lead: str, button: str, action: str, extra: str = "") -> str:
    return f"""<section class="sign-card edge-card" aria-labelledby="title">
  {PLANE}
  <p class="eyebrow">MissionCopilot · Manager dashboard</p>
  <h1 id="title">{heading}</h1>
  <p class="lead">{lead}</p>
  <button class="pill primary" type="button" data-action="{action}"{extra}>
    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a7 7 0 0 0-7 7v3m14 0v-3a7 7 0 0
    0-11-5.7M9 21c1.5-2 2-4.5 2-8a1 1 0 0 1 2 0c0 4-.6 6.8-2.2 9M15.5 20c.8-1.8 1.5-4.2 1.5-7M5
    16c.6 0 1.2-.2 1.7-.6"/></svg>
    {button}
  </button>
  <p class="status" role="status" aria-live="polite"></p>
  <p class="fine">Your Mac's Touch ID or password signs you in. No password is kept here.</p>
</section>"""


router = APIRouter(prefix="/dashboard", dependencies=[Depends(site)])


@router.get("/sign-in", response_class=HTMLResponse)
def sign_in_page() -> HTMLResponse:
    return page("Sign in", _card("Welcome back", "Sign in to review the missions' reports, "
                                 "every sentence with its proof.", "Sign in with Touch ID",
                                 "sign-in"), cover=True)  # fmt: skip


@router.get("/invite/{code}", response_class=HTMLResponse)
def invite_page(code: str) -> HTMLResponse:
    extra = f' data-code="{escape(code)}"'
    return page("Create your passkey", _card(
        "Create your passkey", "One touch on your Mac's Touch ID makes a passkey for this "
        "dashboard. It never leaves your Mac.", "Create your passkey", "register", extra),
        cover=True)  # fmt: skip


def reader(request: Request, org_id: str):
    """The organization's dashboard reads: a test may set app.state.dashboard_reader; the server
    opens the organization's own database (db/dashboard_data.py)."""
    made = getattr(request.app.state, "dashboard_reader", None)
    if made is not None:
        return made(org_id)
    databases = request.app.state.databases
    found = databases.dashboard_for(org_id) if databases is not None else None
    if found is None:
        raise HTTPException(404)
    return found


@router.get("", response_model=None)
def home(request: Request) -> Response:
    token = request.cookies.get(COOKIE)
    user = request.app.state.dashboard.session(token) if token else None
    if user is None:
        return RedirectResponse("/dashboard/sign-in", status_code=303)
    portfolio = reader(request, user.org_id).portfolio(user.user_id)
    palette = [(row.title, row.country or "Mission", f"/dashboard/missions/{row.id}")
               for row in portfolio.rows] + [("All missions", "Page", "/dashboard")]  # fmt: skip
    return shell("Missions", user.name, render_portfolio(portfolio), palette)


def install_dashboard_pages(app: FastAPI) -> None:
    app.include_router(router)
    app.include_router(missions)
    app.mount("/dashboard/static", StaticFiles(directory=str(STATIC)), name="dashboard-static")
