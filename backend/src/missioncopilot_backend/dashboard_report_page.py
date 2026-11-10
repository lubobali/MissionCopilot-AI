"""The report page (#177): the aide-memoire's shape, the document managers already read. The header
and the badge ("Signed with Face ID on the officer's iPhone, verified by the server" only when the
stored approval checks again with the kept key, on every load); the ratings table; the sections in
order with every sentence numbered (the number opens its proof); the action plan with what the site
walk saw. Strictly confidential sentences reach only the `confidential` role. A print view in CSS
(report.css). Every value escaped."""

from html import escape

from missioncopilot_backend.dashboard_decision import panel
from missioncopilot_backend.dashboard_portfolio import moment
from missioncopilot_backend.dashboard_project_page import rating_row
from missioncopilot_backend.dashboard_proof import may_see, proof
from missioncopilot_backend.db.dashboard_report import SECTIONS, Action, Line, ReportView

LANGUAGES = {"en": "English", "fr": "French"}


def seal(view: ReportView, verified: bool) -> str:
    stored = view.stored
    who = (f"<small>Approved by {escape(stored.approved_by)}, {moment(stored.approved_at)}"
           f" · received {moment(stored.received_at)}</small>")  # fmt: skip
    if verified:
        return (f'<p class="seal ok"><span class="tick" aria-hidden="true">✓</span><span>'
                f"<b>Signed with Face ID on the officer's iPhone</b> · verified by the server"
                f"{who}</span></p>")  # fmt: skip
    return (f'<p class="seal bad" role="alert"><span class="tick" aria-hidden="true">!</span><span>'
            f"<b>Not verified</b> · the stored approval does not check with the officer's key. "
            f"Do not rely on this report.{who}</span></p>")  # fmt: skip


def line_html(line: Line, roles: tuple[str, ...]) -> str:
    if not may_see(line.classification, roles):
        return (f'<li class="line hidden-line" value="{line.number}"><span class="num">'
                f"{line.number}</span><em>Strictly confidential: not shown for your role.</em>"
                "</li>")  # fmt: skip
    return (f'<li class="line" id="s{line.number}" value="{line.number}"><button class="num" '
            f'type="button" popovertarget="proof-{line.number}" aria-label="Sentence '
            f'{line.number}: see its proof">{line.number}</button>'
            f"<span>{escape(line.text)}</span></li>")  # fmt: skip


def action_plan(actions: list[Action]) -> str:
    if not actions:
        return ""
    rows = "".join(
        f'<tr><th scope="row">{escape(a.action)}</th><td>{escape(a.responsible)}</td>'
        f"<td>{escape(a.deadline or '')}</td><td>{escape(a.status)}</td>"
        f"<td>{escape(a.seen) if a.seen else '<span class=muted>Not checked on this visit</span>'}"
        f"</td></tr>"
        for a in actions
    )
    return f"""<table class="plan"><caption>Action plan</caption><thead><tr>
  <th scope="col">Action</th><th scope="col">Responsible</th><th scope="col">Deadline</th>
  <th scope="col">Status</th><th scope="col">What the site walk saw</th></tr></thead>
  <tbody>{rows}</tbody></table>"""


def sections(view: ReportView, roles: tuple[str, ...]) -> str:
    out, number = [], 0
    for key, title in SECTIONS:
        lines = [line for line in view.lines if line.section == key]
        plan = action_plan(view.actions) if key == "agreedActions" else ""
        if not lines and not plan:
            continue
        number += 1
        items = "".join(line_html(line, roles) for line in lines)
        out.append(f'<section class="part"><h2 class="caps small">{number}. <b>{title}</b></h2>'
                   f'<ol class="lines">{items}</ol>{plan}</section>')  # fmt: skip
    return "".join(out)


def render(view: ReportView, roles: tuple[str, ...], verified: bool) -> str:
    row, stored = view.row, view.stored
    ratings = "".join(rating_row(r) for r in view.ratings)
    proofs = "".join(proof(line, row.id, roles) for line in view.lines
                     if may_see(line.classification, roles))  # fmt: skip
    as_of = f" · as of {escape(view.ratings_as_of)}" if view.ratings_as_of else ""
    return f"""<nav class="crumbs" aria-label="You are here"><a href="/dashboard">Missions</a>
  <span aria-hidden="true">/</span> <a href="/dashboard/missions/{escape(row.id)}/project">{
        escape(row.title)
    }</a> <span aria-hidden="true">/</span> <span>Aide-memoire</span></nav>
<article class="paper">
<header class="hero report-head">
  <p class="eyebrow">{escape(row.project_ref or "Mission")} · Aide-memoire</p>
  <h1 class="title vt-mission">{escape(row.title)}</h1>
  {seal(view, verified)}
  <dl class="facts"><div><dt>Country</dt><dd>{escape(row.country or "")}</dd></div>
    <div><dt>Approved</dt><dd>{moment(stored.approved_at)}</dd></div>
    <div><dt>Language</dt><dd>{LANGUAGES.get(stored.language, escape(stored.language))}</dd></div>
    <div><dt>Sentences</dt><dd>{len(view.lines)}, each with its proof</dd></div></dl>
  <p class="tools"><button class="pill" type="button" data-action="print">Print</button>
    <a class="pill ghost" href="/dashboard/missions/{escape(row.id)}/project">Project page</a>
    <a class="pill ghost" href="/dashboard/missions/{escape(row.id)}/trail">Audit trail</a></p>
  {panel(view, verified)}
</header>
<section class="part"><h2 class="caps small">Ratings <b>now and before</b></h2>
  <table class="ratings"><thead><tr><th scope="col">Area</th><th scope="col">Before</th>
  <th scope="col">Now</th><th scope="col">Trend</th></tr></thead><tbody>{ratings}</tbody></table>
  <p class="note">From the mission pack{as_of}</p></section>
{sections(view, roles)}
</article>
{proofs}"""
