"""The portfolio (#175, step 8.5.2): the manager's first screen, in the bank's reading order. Three
numbers, the missions table (reports to review first) and the site visits radar. Status and risk say
their words and carry an icon, never colour alone (WCAG 1.4.1); no coordinates are printed."""

import math
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


RING = {"High": 24, "Substantial": 46, "Moderate": 66, "Low": 84}  # riskier: nearer the centre


def radar(rows: list[MissionRow]) -> str:
    """One dot per mission: its distance from the centre is its risk now (the bullseye is where to
    look first), a report to review pulses, each dot opens its mission. No coordinates printed."""
    blips = []
    for i, row in enumerate(rows):
        angle = math.tau * i / max(len(rows), 1) - math.pi / 2
        r = RING.get(row.risk_now or "", 90)
        x, y = 100 + r * math.cos(angle), 100 + r * math.sin(angle)
        page = "report" if row.status != "in_field" else "project"
        words = f"{row.title}: risk {row.risk_now or 'not rated'}, {STATUS[row.status][0]}"
        link = f"/dashboard/missions/{escape(row.id)}/{page}"
        blips.append(f'<a class="blip {row.status}" href="{link}"><title>{escape(words)}</title>'

                     f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5"/></a>')  # fmt: skip
    points = sum(len(row.points) for row in rows)
    note = (f"{len(rows)} mission{'s' if len(rows) != 1 else ''} · nearer the centre, higher risk"
            f" · {points} site point{'s' if points != 1 else ''} received")  # fmt: skip
    return f"""<section class="card visits" aria-labelledby="visits">
  <h2 id="visits" class="caps small">Risk <b>radar</b></h2>
  <svg class="radar" viewBox="0 0 200 200" role="img" aria-label="{escape(note)}">
    <circle class="ring high" cx="100" cy="100" r="35"/>
    <circle class="ring" cx="100" cy="100" r="56"/>
    <circle class="ring" cx="100" cy="100" r="76"/><circle class="ring" cx="100" cy="100" r="94"/>
    <path class="axis" d="M100 6v188M6 100h188"/>
    <g class="sweep"><path d="M100 100 L100 6 A94 94 0 0 1 166.5 33.5 Z"/></g>{"".join(blips)}
  </svg>
  <p class="legend"><span class="key received"></span>To review
    <span class="key in_field"></span>In the field <span class="key endorsed"></span>Endorsed
    <span class="key sent_back"></span>Sent back</p>
  <p class="note">{escape(note)}</p>
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
