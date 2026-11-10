"""The portfolio (#175, step 8.5.2): the manager's first screen, in the bank's reading order. Three
numbers, the missions table (reports to review first) and the site visits radar. Status and risk say
their words and carry an icon, never colour alone (WCAG 1.4.1); no coordinates are printed."""

from datetime import UTC, datetime
from html import escape

from missioncopilot_backend.db.dashboard_data import MissionRow, Portfolio

STATUS = {
    "received": ("Received, to review", "M4 12l5 5L20 6"),
    "sent_back": ("Sent back to the officer", "M9 14L4 9l5-5M4 9h11a5 5 0 0 1 0 10h-3"),
    "endorsed": ("Endorsed", "M12 2l3 6 6 .8-4.5 4.4 1 6.3L12 16.6 6.5 19.5l1-6.3L3 8.8 9 8z"),
    "in_field": (
        "In the field",
        "M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11zM12 12a2 2 0 1 0 0-4",
    ),
}
RISK = ["Low", "Moderate", "Substantial", "High"]


def day(timestamp: float | None) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%-d %b %Y") if timestamp else "Not yet"


def moment(at: float) -> str:
    return datetime.fromtimestamp(at, UTC).strftime("%-d %b %Y, %H:%M UTC")


def status_pill(status: str) -> str:
    words, path = STATUS[status]
    return (f'<span class="status {status}"><svg viewBox="0 0 24 24" aria-hidden="true">'
            f'<path d="{path}"/></svg>{escape(words)}</span>')  # fmt: skip


def risk(row: MissionRow) -> str:
    if not row.risk_now:
        return '<span class="muted">No rating</span>'
    now, before = row.risk_now, row.risk_before
    if before in RISK and now in RISK and before != now:
        way = "up" if RISK.index(now) > RISK.index(before) else "down"
        arrow = "↑" if way == "up" else "↓"
        trend = (f'<span class="trend {way}" aria-hidden="true">{arrow}</span>'
                 f"<small>{way} from {escape(before)}</small>")  # fmt: skip
    else:
        trend = '<span class="trend same" aria-hidden="true">→</span><small>same as before</small>'
    return f'<span class="risk"><b>{escape(now)}</b> {trend}</span>'


def review_link(row: MissionRow) -> str:
    """A received report's status opens the report itself; other statuses are words only."""
    if row.status == "in_field":
        return status_pill(row.status)
    return (f'<a class="review-link" href="/dashboard/missions/{escape(row.id)}/report">'
            f"{status_pill(row.status)}</a>")  # fmt: skip


def row_html(row: MissionRow) -> str:
    ref = f'<span class="ref">{escape(row.project_ref)}</span>' if row.project_ref else ""
    flags = (
        f'<span class="flags">{row.red_flags} red flag{"s" if row.red_flags != 1 else ""}</span>'
    )
    return f"""<tr>
  <td><a class="mission-link" href="/dashboard/missions/{escape(row.id)}/project">{
        escape(row.title)
    }</a>
    {ref}
    {flags if row.red_flags else ""}</td>
  <td>{escape(row.country or "")}</td>
  <td>{review_link(row)}</td>
  <td>{risk(row)}</td>
  <td class="num">{day(row.received_at)}</td>
</tr>"""


def radar(rows: list[MissionRow]) -> str:
    points = [(row, point) for row in rows for point in row.points]
    dots = "".join(f'<circle class="dot" cx="{100 + 18 * i}" cy="{100 - 12 * i}" r="4"/>'
                   for i, _ in enumerate(points))  # fmt: skip
    if points:
        row, (_, _, accuracy) = points[0]
        note = (f"{len(points)} sample point{'s' if len(points) != 1 else ''} · "
                f"{escape(row.title)} · within {accuracy:.0f} m")  # fmt: skip
    else:
        note = "No site visit received yet"
    return f"""<section class="card visits" aria-labelledby="visits">
  <h2 id="visits" class="caps small">Site <b>visits</b></h2>
  <svg class="radar" viewBox="0 0 200 200" role="img" aria-label="{note}">
    <circle class="ring" cx="100" cy="100" r="90"/><circle class="ring" cx="100" cy="100" r="60"/>
    <circle class="ring" cx="100" cy="100" r="30"/><path class="axis" d="M100 10v180M10 100h180"/>
    <g class="sweep"><path d="M100 100 L100 10 A90 90 0 0 1 163.6 36.4 Z"/></g>{dots}
  </svg>
  <p class="note">{note}</p>
</section>"""


def stat(count: int, label: str, line: str) -> str:
    return f"""<div class="stat edge-card" data-beam="hover">
    <p class="number" data-count="{count}">{count}</p><p class="label">{label}</p>
    <p class="line">{line}</p></div>"""


def render(portfolio: Portfolio) -> str:
    rows = "\n".join(row_html(row) for row in portfolio.rows)
    table = (f"""<table class="missions">
  <thead><tr><th scope="col">Mission</th><th scope="col">Country</th><th scope="col">Status</th>
  <th scope="col">Overall risk</th><th scope="col">Received</th></tr></thead>
  <tbody>
{rows}
  </tbody>
</table>""" if portfolio.rows else '<p class="empty">No mission yet. Reports appear here when an '
             "officer sends one from the iPhone.</p>")  # fmt: skip
    return f"""<section class="hero">
  <p class="eyebrow">Manager dashboard</p>
  <h1 class="caps">Missions <b>to review</b></h1>
  <p class="lead">Every report arrives signed on the officer's iPhone, each sentence with its
    proof.</p>
</section>
<section class="stats" aria-label="At a glance">
  {stat(portfolio.to_review, "Reports to review", "Signed with Face ID, checked by the server")}
  {stat(portfolio.red_flags, "Red flags raised", "Found by fixed rules, never by the AI")}
  {stat(portfolio.endorsed, "Endorsed", "Signed off by a manager with Touch ID")}
</section>
<section class="split">
  <div class="card table-card">{table}</div>
  {radar(portfolio.rows)}
</section>"""
