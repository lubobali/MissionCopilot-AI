"""The audit trail page (#178, step 8.8.3): every step of a mission's report in time order, from
what was stored (each version approved on the iPhone and received, each manager's decision) and
from the hash-chained audit log (syncs, pack downloads, decisions). "Chain intact" only when the
whole log verifies again on this load (audit.verify_chain); else the problems it found. Every value
escaped."""

from html import escape

from missioncopilot_backend.audit import AuditEvent
from missioncopilot_backend.dashboard_portfolio import moment
from missioncopilot_backend.db.dashboard_report import Trail

LOGGED = {
    "pack_downloaded": "Mission pack downloaded to the iPhone",
    "mission_synced": "Report sent from the iPhone",
    "report_endorsed": "Endorsement logged",
    "report_sent_back": "Send back logged",
}


def steps(trail: Trail, events: list[AuditEvent]) -> list[tuple[float, str, str, str]]:
    """(when, kind, what, who), oldest first."""
    found = []
    for v in trail.versions:
        found.append((v.approved_at, "approved", f"Version {v.version} approved with Face ID on the"
                      f" officer's iPhone (draft {v.draft_id})", v.approved_by))  # fmt: skip
        found.append((v.received_at, "received", f"Version {v.version} received and checked by the"
                      " server", "Server"))  # fmt: skip
    for r in trail.reviews:
        what = (f"Version {r.version} endorsed with Touch ID" if r.decision == "endorsed"
                else f"Version {r.version} sent back: “{r.note}”")  # fmt: skip
        found.append((r.reviewed_at, r.decision, what, r.reviewer_name))
    for e in events:
        if e.kind in LOGGED:
            found.append((e.at, "logged", f"{LOGGED[e.kind]} · log entry {e.seq}", e.actor or ""))
    return sorted(found, key=lambda step: step[0])


def chain(problems: list[str], checked: int) -> str:
    if not problems:
        return (f'<p class="seal ok"><span class="tick" aria-hidden="true">✓</span><span><b>Chain '
                f"intact</b> · {checked} log entries checked again now, each follows the one before"
                "</span></p>")  # fmt: skip
    found = "; ".join(escape(p) for p in problems[:5])
    return (f'<p class="seal bad" role="alert"><span class="tick" aria-hidden="true">!</span><span>'
            f"<b>Chain broken</b> · {found}</span></p>")  # fmt: skip


def render(trail: Trail, events: list[AuditEvent], problems: list[str], checked: int) -> str:
    row = trail.row
    items = (
        "".join(
            f'<li class="step {kind}"><time>{moment(at)}</time><p>{escape(what)}</p>'
            f"<small>{escape(who)}</small></li>"
            for at, kind, what, who in steps(trail, events)
        )
        or '<li class="empty">Nothing yet: no report received.</li>'
    )
    base = f"/dashboard/missions/{escape(row.id)}"
    return f"""<nav class="crumbs" aria-label="You are here"><a href="/dashboard">Missions</a>
  <span aria-hidden="true">/</span> <a href="{base}/project">{escape(row.title)}</a>
  <span aria-hidden="true">/</span> <span>Audit trail</span></nav>
<article class="paper">
<header class="hero report-head">
  <p class="eyebrow">{escape(row.project_ref or "Mission")} · Audit trail</p>
  <h1 class="title vt-mission">{escape(row.title)}</h1>
  {chain(problems, checked)}
  <p class="tools"><a class="pill ghost" href="{base}/report">The report</a></p>
</header>
<section class="part"><h2 class="caps small">Every <b>step</b></h2>
  <ol class="timeline">{items}</ol></section>
</article>"""
