"""The audit trail page (#178, step 8.8.3): every step of a mission's report in time order, from
what was stored (each version approved on the iPhone and received, each manager's decision) and
from the hash-chained audit log (syncs, pack downloads, decisions). "Chain intact" only when the
whole log verifies again on this load (audit.verify_chain); else the problems it found. Every value
escaped."""

from html import escape

from missioncopilot_backend.audit import AuditEvent
from missioncopilot_backend.dashboard_layout import titled
from missioncopilot_backend.dashboard_portfolio import moment, officer
from missioncopilot_backend.db.dashboard_report import Trail

LOGGED = {
    "pack_downloaded": "Mission pack downloaded to the iPhone",
    "mission_synced": "Report sent from the iPhone",
    "report_endorsed": "Endorsement logged",
    "report_sent_back": "Send back logged",
}

BY = {"pack_downloaded": "The officer's iPhone", "mission_synced": "The officer's iPhone",
      "report_endorsed": "A manager", "report_sent_back": "A manager"}  # fmt: skip


def upper_first(words: str) -> str:
    return words[:1].upper() + words[1:]


def steps(trail: Trail, events: list[AuditEvent]) -> list[tuple[float, str, str, str]]:
    """(when, kind, what, who), oldest first."""
    found = []
    for v in trail.versions:
        found.append((v.approved_at, "approved", f"Version {v.version} approved with Face ID on the"
                      f" officer's iPhone", upper_first(officer(v.approved_by))))  # fmt: skip
        found.append((v.received_at, "received", f"Version {v.version} received and checked by the"
                      " server", "Server"))  # fmt: skip
    for r in trail.reviews:
        what = (f"Version {r.version} endorsed with Touch ID" if r.decision == "endorsed"
                else f"Version {r.version} sent back: “{r.note}”")  # fmt: skip
        found.append((r.reviewed_at, r.decision, what, r.reviewer_name))
    names = {r.reviewer_id: r.reviewer_name for r in trail.reviews}  # Lubo: names, never user ids
    for e in events:
        if e.kind in LOGGED:
            who = names.get(e.actor or "") or BY[e.kind]
            found.append((e.at, "logged", f"{LOGGED[e.kind]} · log entry {e.seq}", who))
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
    return f"""<article class="paper">
<header class="hero report-head">
  <p class="eyebrow">{escape(row.project_ref or "Mission")} · Audit trail</p>
  {titled(row.title, f"/dashboard/missions/{row.id}/report", "the report")}
  {chain(problems, checked)}
</header>
<section class="part"><h2 class="caps small">Every <b>step</b></h2>
  <ol class="timeline">{items}</ol></section>
</article>"""
