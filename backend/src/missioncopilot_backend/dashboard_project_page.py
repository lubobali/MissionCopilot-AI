"""The project page (#176, step 8.6.2): a fact sheet from the pack, financing with a disbursed bar,
the ratings table as the bank writes it (area, before, now, trend in words), components, and the
mission's reports listed like a documents list. Every value escaped."""

from html import escape

from missioncopilot_backend.dashboard_layout import titled
from missioncopilot_backend.dashboard_portfolio import day, status_pill
from missioncopilot_backend.db.dashboard_project import ProjectView, Rating

ARROWS = {"better": "↑", "worse": "↓", "same": "→", "unknown": "·"}


def money(amount: int, currency: str) -> str:
    return f"{escape(currency)} {amount:,}"


def rating_row(rating: Rating) -> str:
    words = rating.trend.capitalize() if rating.trend != "unknown" else "No earlier rating"
    before = escape(rating.before or "")
    return (f"<tr><th scope=\"row\">{escape(rating.area)}</th><td>{before}</td>"
            f"<td><b>{escape(rating.now or '')}</b></td><td><span class=\"trend {rating.trend}\" "
            f"aria-hidden=\"true\">{ARROWS[rating.trend]}</span> {words}</td></tr>")  # fmt: skip


def render(view: ProjectView) -> str:
    row = view.row
    facts = "".join(
        f"<div><dt>{escape(k)}</dt><dd>{escape(v)}</dd></div>" for k, v in view.facts.items()
    )
    money_line = ""
    if view.financing:
        f = view.financing
        money_line = f"""<section class="card finance">
  <h2 class="caps small">Financing <b>disbursed</b></h2>
  <p class="big">{money(f.disbursed, f.currency)} of {money(f.total, f.currency)} disbursed ({
            f.percent
        }%)</p>
  <meter class="bar" min="0" max="100" value="{f.percent}" aria-hidden="true"></meter>
  <ul class="components">{
            "".join(
                f"<li><span>{escape(c.name)}</span>"
                f'<span class="num">{money(c.disbursed, f.currency)} of '
                f"{money(c.cost, f.currency)}</span></li>"
                for c in view.components
            )
        }</ul>
</section>"""
    ratings = ""
    if view.ratings:
        as_of = (
            f'<p class="note">As of {escape(view.ratings_as_of)}</p>' if view.ratings_as_of else ""
        )
        ratings = f"""<section class="card">
  <h2 class="caps small">Ratings <b>now and before</b></h2>
  <table class="ratings"><thead><tr><th scope="col">Area</th><th scope="col">Before</th>
  <th scope="col">Now</th><th scope="col">Trend</th></tr></thead>
  <tbody>{"".join(rating_row(r) for r in view.ratings)}</tbody></table>{as_of}
</section>"""
    documents = (
        "".join(
            f"""<li class="document"><span class="kind">Aide-memoire</span>
  <span class="num">Approved
  {day(r.approved_at)}, received {day(r.received_at)}</span>{status_pill(r.status)}
  <a class="pill ghost" href="/dashboard/missions/{escape(row.id)}/report">Open the report</a>
  </li>"""
            for r in view.reports
        )
        or '<li class="empty">No report received yet.</li>'
    )
    return f"""<section class="hero">
  <p class="eyebrow">{escape(row.project_ref or "Mission")}</p>
  {titled(row.title, "/dashboard", "missions")}
  <p class="lead">{escape(view.objective)}</p>
  <dl class="facts">{facts}</dl>
</section>
<section class="split">
  <div class="stack">{ratings}
    <section class="card"><h2 class="caps small">Mission <b>reports</b></h2>
      <ul class="documents">{documents}</ul></section></div>
  {money_line}
</section>"""
