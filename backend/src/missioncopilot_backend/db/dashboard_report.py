"""The report page's data (#177, step 8.7.1): the approved report rebuilt from what the phone signed
and sent (ADR 0009: sentence -> facts -> evidence), nothing rewritten by the server. A pack source
shows the record its region points at, read from the exact file the phone cited (by its SHA-256);
the action plan is the pack's agreed actions with what the site walk saw."""

import json
import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

import psycopg

from missioncopilot_backend.db.dashboard_project import Rating, day
from missioncopilot_backend.db.reviews import Review
from missioncopilot_backend.db.sync import StoredReport

if TYPE_CHECKING:
    from missioncopilot_backend.db.dashboard_data import MissionRow

CONFIDENTIAL = "strictly_confidential"
SECTIONS = [("mission", "Mission"), ("project", "Project"), ("findings", "Main findings"),
            ("agreedActions", "Agreed actions"), ("nextSteps", "Next steps")]  # fmt: skip
PACK_PLACE = re.compile(r"^([\w./-]+\.json)#(/\S*?)(?: sum)? sha256:([0-9a-f]{64})$")


@dataclass(frozen=True)
class Source:
    seq: int
    kind: str  # photo, scan, audio, pack, walk
    captured_at: str | None
    region: str | None
    has_file: bool
    records: list[tuple[str, object]]  # pack sources: (file#pointer, the record)


@dataclass(frozen=True)
class ProofFact:
    id: str
    name: str
    value: str
    unit: str | None
    rule: str
    classification: str
    sources: list[Source]


@dataclass(frozen=True)
class Line:
    number: int
    section: str
    text: str
    classification: str
    facts: list[ProofFact]


@dataclass(frozen=True)
class Action:
    action: str
    responsible: str
    deadline: str | None
    status: str
    seen: str | None


@dataclass(frozen=True)
class ReportView:
    row: "MissionRow"
    ratings: list[Rating]
    ratings_as_of: str | None
    actions: list[Action]
    lines: list[Line]
    stored: StoredReport
    reviews: list[Review] = field(default_factory=list)  # every version's decision (#178)
    on_team: bool = False  # the manager is on the mission's team: may not decide

    @property
    def decision(self) -> Review | None:
        """The decision on the newest version, if a manager made it."""
        return next((r for r in self.reviews if r.version == self.stored.version), None)


@dataclass(frozen=True)
class KeptFile:
    kind: str
    data: bytes
    confidential_only: bool  # cited only by strictly confidential facts


def pointer(doc: object, path: str) -> object | None:
    """RFC 6901: the value at `path`, or None."""
    found = doc
    for raw in path.split("/")[1:] if path else []:
        part = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(found, dict) and part in found:
            found = found[part]
        elif isinstance(found, list) and part.isdigit() and int(part) < len(found):
            found = found[int(part)]
        else:
            return None
    return found


def pack_places(region: str | None) -> list[tuple[str, str, str]]:
    """(file, pointer, sha256) for each pack field a region names; merged regions join with |."""
    places = []
    for part in (region or "").split(" | "):
        found = PACK_PLACE.match(part.strip())
        if found:
            places.append((found[1], found[2], found[3]))
    return places


def seen_for(section: dict, facts: list[ProofFact]) -> list[Action]:
    """The agreed actions, each with the walk's check of it (its source region names the action)."""
    seen = {
        s.region[len("action:") :]: f.value
        for f in facts if f.rule == "walk-answer"
        for s in f.sources if s.region and s.region.startswith("action:")
    }  # fmt: skip
    items = section.get("actions", [])
    return [
        Action(a["action"], str(a.get("responsible", "")), day(a.get("deadline")),
               str(a.get("status", "")), seen.get(a["action"]))
        for a in (items if isinstance(items, list) else [])
        if isinstance(a, dict) and isinstance(a.get("action"), str)
    ]  # fmt: skip


def _pack_file(conn: psycopg.Connection, sha256: str) -> object | None:
    row = conn.execute("SELECT data FROM pack_files WHERE sha256 = %s", [sha256]).fetchone()
    try:
        return json.loads(bytes(row[0])) if row else None
    except ValueError:
        return None


def facts(conn: psycopg.Connection, mission_id: str) -> dict[str, ProofFact]:
    rows = conn.execute(
        "SELECT seq, kind, payload FROM evidence WHERE mission_id = %s", [mission_id]
    ).fetchall()
    evidence = {seq: (kind, json.loads(bytes(payload)).get("capturedAt"))
                for seq, kind, payload in rows}  # fmt: skip
    kept = {seq for (seq,) in conn.execute(
        "SELECT seq FROM evidence_files WHERE mission_id = %s", [mission_id])}  # fmt: skip
    files: dict[str, object | None] = {}
    sources: dict[str, list[Source]] = {}
    for fact_id, seq, region in conn.execute(
        "SELECT fact_id, seq, region FROM fact_sources WHERE mission_id = %s ORDER BY fact_id, seq",
        [mission_id],
    ).fetchall():
        records = []
        for path, place, sha in pack_places(region):
            if sha not in files:
                files[sha] = _pack_file(conn, sha)
            records.append((f"{path}#{place}", pointer(files[sha], place)))
        kind, captured = evidence.get(seq, ("unknown", None))
        sources.setdefault(fact_id, []).append(
            Source(seq, kind, captured, region, seq in kept, records)
        )
    rows = conn.execute(
        "SELECT id, name, value, unit, rule_id, classification FROM facts WHERE mission_id = %s",
        [mission_id],
    ).fetchall()
    return {i: ProofFact(i, n, v, u, r, c, sources.get(i, [])) for i, n, v, u, r, c in rows}


def lines(report: StoredReport, known: dict[str, ProofFact]) -> list[Line]:
    return [
        Line(n, s.section, s.text, s.classification, [known[f] for f in s.fact_ids if f in known])
        for n, s in enumerate(report.sentences, start=1)
    ]


def kept_file(conn: psycopg.Connection, mission_id: str, seq: int) -> KeptFile | None:
    row = conn.execute(
        "SELECT e.kind, f.data FROM evidence_files f JOIN evidence e ON e.mission_id = f.mission_id"
        " AND e.seq = f.seq WHERE f.mission_id = %s AND f.seq = %s",
        [mission_id, seq],
    ).fetchone()
    if row is None:
        return None
    open_fact = conn.execute(
        "SELECT 1 FROM fact_sources s JOIN facts f"
        " ON f.mission_id = s.mission_id AND f.id = s.fact_id"
        " WHERE s.mission_id = %s AND s.seq = %s AND f.classification <> %s LIMIT 1",
        [mission_id, seq, CONFIDENTIAL],
    ).fetchone()
    return KeptFile(row[0], bytes(row[1]), open_fact is None)


@dataclass(frozen=True)
class Version:
    version: int
    draft_id: str
    approved_by: str
    approved_at: float
    received_at: float


@dataclass(frozen=True)
class Trail:
    """Every version of a mission's report and every decision, for the audit trail page (#178)."""

    row: "MissionRow"
    versions: list[Version]
    reviews: list[Review]


def versions(conn: psycopg.Connection, mission_id: str) -> list[Version]:
    rows = conn.execute(
        "SELECT version, draft_id, approved_by, approved_at, received_at FROM reports"
        " WHERE mission_id = %s ORDER BY version",
        [mission_id],
    ).fetchall()
    return [Version(*row) for row in rows]
