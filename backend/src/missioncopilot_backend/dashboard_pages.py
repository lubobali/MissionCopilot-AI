"""The dashboard's pages (#174, step 8.4.4; the look of #175): built on the server as plain HTML,
with this server's stylesheet, fonts and one script (WebAuthn needs the browser's
navigator.credentials). Every value written into a page is escaped. The sign-in pages need no
session; every other page does, and without one goes to sign-in."""

import mimetypes
from html import escape
from importlib.resources import files

from fastapi import APIRouter, Depends, FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from missioncopilot_backend.dashboard_routes import COOKIE, site

STATIC = files("missioncopilot_backend") / "dashboard_static"
mimetypes.add_type(
    "font/woff2", ".woff2"
)  # a slim server image has no type for it (found on staging)
# The app's brand (BrandMedallion on the iPhone): Lubo's logo on a white tile, a glowing trail, and
# the airplane (Material Symbols' "flight", Apache-2.0), in a glass pill.
PLANE = (
    '<span class="medallion"><img class="logo" src="/dashboard/static/logo.png" alt="" width="36" '
    'height="38"><svg class="mark" viewBox="0 0 72 32" aria-hidden="true"><path class="trail" '
    'd="M2 22 C 20 30, 36 28, 50 16"/>'
    '<g class="plane" transform="translate(48 0) rotate(45 12 12)">'
    '<path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22'
    'l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"/></g></svg></span>'
)


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


@router.get("", response_model=None)
def home(request: Request) -> Response:
    token = request.cookies.get(COOKIE)
    user = request.app.state.dashboard.session(token) if token else None
    if user is None:
        return RedirectResponse("/dashboard/sign-in", status_code=303)
    return page(
        "Missions",
        f"""<header class="top">
  <p class="brand">{PLANE}<span>MissionCopilot</span></p>
  <form method="post" action="/v1/dashboard/sign-out">
    <button class="pill ghost">Sign out</button>
  </form>
</header>
<section class="hello"><p class="eyebrow">Signed in</p><h1>Welcome, {escape(user.name)}</h1>
<p class="lead">The missions and their reports come here next.</p></section>""",
    )


def install_dashboard_pages(app: FastAPI) -> None:
    app.include_router(router)
    app.mount("/dashboard/static", StaticFiles(directory=str(STATIC)), name="dashboard-static")
