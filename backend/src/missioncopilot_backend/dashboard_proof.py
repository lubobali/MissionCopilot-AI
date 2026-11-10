"""A sentence's proof (#177, step 8.7.2): the facts it stands on and each fact's evidence, in a
native popover (no script). A pack source shows the record as fields; a walk source names the
question or the agreed action; a photo or scanned page shows the file; a debrief plays the
recording and names the words' place in the on-device transcript. Strictly confidential facts and
files reach only the `confidential` role. Every value escaped."""

import re
from html import escape

from missioncopilot_backend.db.dashboard_report import CONFIDENTIAL, Line, ProofFact, Source

CONFIDENTIAL_ROLE = "confidential"
KINDS = {"pack": "Mission pack record", "walk": "Site walk", "photo": "Site photo",
         "scan": "Scanned page", "audio": "Debrief recording"}  # fmt: skip
RULES = {"pack-record": "Read from the mission pack", "walk-answer": "Answered on the site walk",
         "red-flag": "Red-flag rule"}  # fmt: skip
TEXT_PLACE = re.compile(r"^(\S+) text (\d+)\+(\d+)$")
TYPES = [(b"\xff\xd8\xff", "image/jpeg"), (b"\x89PNG\r\n\x1a\n", "image/png")]


def sniff(data: bytes) -> str | None:
    """The file's type from its first bytes: JPEG, PNG or an MPEG-4 recording; else None."""
    for magic, kind in TYPES:
        if data.startswith(magic):
            return kind
    return "audio/mp4" if data[4:8] == b"ftyp" else None


def may_see(classification: str, roles: tuple[str, ...]) -> bool:
    return classification != CONFIDENTIAL or CONFIDENTIAL_ROLE in roles


def _record(value: object) -> str:
    if isinstance(value, dict):
        rows = "".join(f"<div><dt>{escape(str(k))}</dt><dd>{escape(str(v))}</dd></div>"
                       for k, v in value.items() if not isinstance(v, (dict, list)))  # fmt: skip
        return f'<dl class="record">{rows}</dl>'
    return f'<p class="record">{escape(str(value))}</p>'


def _place(source: Source) -> str:
    region = source.region or ""
    if region.startswith("question:"):
        return f"Question: {escape(region[9:])}"
    if region.startswith("action:"):
        return f"Agreed action: {escape(region[7:])}"
    found = TEXT_PLACE.match(region)
    if found and source.kind == "audio":
        return (f"Words {found[2]}+{found[3]} of the on-device transcript "
                f"({escape(found[1])}); listen below")  # fmt: skip
    if found:
        return f"Words {found[2]}+{found[3]} of the page reading ({escape(found[1])})"
    return ""


def source_html(source: Source, mission_id: str) -> str:
    src = f"/dashboard/missions/{escape(mission_id)}/evidence/{source.seq}"
    label = KINDS.get(source.kind, "Evidence")
    if source.records:
        body = "".join(f'<p class="where">{escape(place)}</p>{_record(value)}'
                       for place, value in source.records)  # fmt: skip
    elif source.has_file and source.kind in ("photo", "scan"):
        body = f'<img loading="lazy" src="{src}" alt="{label}, evidence item {source.seq}">'
    elif source.has_file and source.kind == "audio":
        body = f'<audio controls preload="none" src="{src}"></audio>'
    elif source.kind in ("photo", "scan", "audio"):
        body = '<p class="note">File not received yet.</p>'
    else:
        body = ""
    place = _place(source)
    when = f" · {escape(source.captured_at)}" if source.captured_at else ""
    return (f'<li class="source {escape(source.kind)}"><p class="kind">{label}'
            f'<small>Item {source.seq}, signed on the phone{when}</small></p>'
            f'{f"<p class=where>{place}</p>" if place else ""}{body}</li>')  # fmt: skip


def fact_html(fact: ProofFact, mission_id: str) -> str:
    unit = f" {escape(fact.unit)}" if fact.unit else ""
    sources = "".join(source_html(s, mission_id) for s in fact.sources)
    return (f'<article class="fact"><p class="value">{escape(fact.value)}{unit}</p>'
            f'<p class="rule">{escape(RULES.get(fact.rule, fact.rule))} · {escape(fact.name)}</p>'
            f'<ol class="sources">{sources}</ol></article>')  # fmt: skip


def proof(line: Line, mission_id: str, roles: tuple[str, ...]) -> str:
    facts = [f for f in line.facts if may_see(f.classification, roles)]
    hidden = len(line.facts) - len(facts)
    more = (
        f'<p class="note">{hidden} strictly confidential fact(s) not shown.</p>' if hidden else ""
    )
    return f"""<div class="proof" id="proof-{line.number}" popover>
  <header><p class="eyebrow">Sentence {line.number} · its proof</p>
    <button class="close" type="button" popovertarget="proof-{line.number}"
      popovertargetaction="hide" aria-label="Close">×</button></header>
  <blockquote>{escape(line.text)}</blockquote>
  {"".join(fact_html(f, mission_id) for f in facts)}{more}
</div>"""
