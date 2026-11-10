"""The report page's decision panel (#178): endorse with Touch ID or send back with a note, or what
was decided, by whom and when. A manager on the mission's team, or a report that does not verify,
gets the reason instead of the buttons. Earlier versions show why they were sent back."""

from html import escape

from missioncopilot_backend.dashboard_portfolio import moment
from missioncopilot_backend.db.dashboard_report import ReportView


def history(view: ReportView) -> str:
    earlier = [r for r in view.reviews if r.version < view.stored.version and r.note]
    items = "".join(
        f"<li>Version {r.version} sent back by {escape(r.reviewer_name)}, {moment(r.reviewed_at)}:"
        f" “{escape(r.note or '')}”</li>"
        for r in earlier
    )
    return f'<ul class="earlier">{items}</ul>' if items else ""


def panel(view: ReportView, verified: bool) -> str:
    mission = escape(view.row.id)
    version = (
        f'<p class="eyebrow">Version {view.stored.version}</p>' if view.stored.version > 1 else ""
    )
    done = view.decision
    if done is not None and done.decision == "endorsed":
        body = (f'<p class="verdict endorsed"><b>Endorsed</b> with Touch ID by '
                f"{escape(done.reviewer_name)}, {moment(done.reviewed_at)}.</p>")  # fmt: skip
    elif done is not None:
        body = (f'<p class="verdict sent_back"><b>Sent back to the officer</b> by '
                f"{escape(done.reviewer_name)}, {moment(done.reviewed_at)}: "
                f"“{escape(done.note or '')}” Waiting for the next version.</p>")  # fmt: skip
    elif view.on_team:
        body = (
            '<p class="verdict">You were on this mission\'s team, so another manager endorses'
            " it (separation of duties).</p>"
        )
    elif not verified:
        body = '<p class="verdict">Not verified, so it cannot be endorsed.</p>'
    else:
        body = f"""<div class="decide">
    <button class="pill endorse" type="button" data-action="endorse" data-mission="{mission}">
      Endorse with Touch ID</button>
    <details class="send-back"><summary class="pill ghost">Send back with a note</summary>
      <form method="post" action="/v1/dashboard/missions/{mission}/send-back">
        <label for="note">Note to the officer</label>
        <textarea id="note" name="note" required maxlength="500" rows="3"
          placeholder="For example: check the bridge numbers against invoice 14."></textarea>
        <button class="pill" type="submit">Send back</button></form></details>
  </div>
  <p class="status" role="status" aria-live="polite"></p>"""
    return f"""<section class="decision" aria-label="Your decision">{version}
  {body}{history(view)}
</section>"""
