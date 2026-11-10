"""The frame every dashboard page shares (#175): a navy band with the app's brand (Lubo's logo, the
trail, the airplane, the glass shine that slides across, as on the iPhone), search (Command-K), the
signed-in manager and sign out; then the page; and the Command-K palette. Every value is escaped."""

from html import escape

from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse

MEDALLION = (
    '<span class="medallion shine"><img class="logo" src="/dashboard/static/logo.png" alt="" '
    'width="36" height="38"><svg class="mark" viewBox="0 0 72 32" aria-hidden="true"><path '
    'class="trail" d="M2 22 C 20 30, 36 28, 50 16"/><g class="plane" transform="translate(48 0) '
    'rotate(45 12 12)"><path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8'
    '-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"/></g></svg></span>'
)
HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{title} · MissionCopilot</title>
<link rel="stylesheet" href="/dashboard/static/dashboard.css">
{pages}<script src="/dashboard/static/dashboard.js" defer></script>
</head>
"""


def titled(title: str, back: str, back_to: str) -> str:
    """The page title with the one way back: a round ‹ to the page one step up (Missions, then
    project, then report). Never the browser's history, so it always goes to the same place."""
    label = f"Back to {back_to}"
    return (f'<div class="titled"><a class="back" href="{escape(back)}"'
            f' aria-label="{escape(label)}" title="{escape(label)}">'
            '<span aria-hidden="true">‹</span></a>'
            f'<h1 class="title vt-mission">{escape(title)}</h1></div>')  # fmt: skip


def head(title: str, inner: bool, styles: tuple[str, ...] = ()) -> str:
    names = ("pages", *styles) if inner else styles
    pages = "".join(f'<link rel="stylesheet" href="/dashboard/static/{n}.css">\n' for n in names)
    return HEAD.format(title=escape(title), pages=pages)


def shell(
    title: str,
    manager: str,
    body: str,
    palette: list[tuple[str, str, str]],
    styles: tuple[str, ...] = (),
) -> HTMLResponse:
    """A signed-in page. `palette`: (label, hint, link) for every place Command-K can open;
    `styles`: the page's own stylesheets after pages.css (report.css)."""
    items = "\n".join(
        f'<li><a class="palette-item" href="{escape(link)}"><span>{escape(label)}</span>'
        f"<small>{escape(hint)}</small></a></li>"
        for label, hint, link in palette
    )
    return HTMLResponse(
        head(title, inner=True, styles=styles)
        + f"""<body class="app">
<a class="skip" href="#main">Skip to content</a>
<header class="band">
  <a class="brand" href="/dashboard" aria-label="MissionCopilot, all missions">{MEDALLION}
    <span>MissionCopilot</span></a>
  <button class="search" type="button" data-action="palette" aria-keyshortcuts="Meta+K Control+K">
    <span>Search missions and pages</span><kbd>⌘K</kbd></button>
  <div class="who"><span>{escape(manager)}</span>
    <form method="post" action="/v1/dashboard/sign-out"><button class="pill ghost">Sign out</button>
    </form></div>
</header>
<main id="main">
{body}
</main>
<dialog id="palette" aria-label="Search missions and pages">
  <input type="search" placeholder="Type a mission, a country or a page" aria-label="Search"
    autocomplete="off">
  <ul>
{items}
  </ul>
  <p class="palette-empty" hidden>Nothing matches.</p>
</dialog>
</body>
</html>
"""
    )


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
