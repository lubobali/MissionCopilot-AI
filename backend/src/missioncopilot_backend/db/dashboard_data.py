"""What the manager dashboard reads (#175 onwards), as a manager of one organization (db/session.py,
as_manager: read-only policies). Every value comes from what the phone sent and signed, or from the
pack the server signed: nothing is typed into the dashboard."""

import json
import re
from dataclasses import dataclass, field
from typing import Literal

import psycopg
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db import dashboard_project as page
from missioncopilot_backend.db import dashboard_report as paper
from missioncopilot_backend.db.session import as_manager
from missioncopilot_backend.db.sync import read_report

Status = Literal["received", "sent_back", "endorsed", "in_field"]
ORDER: dict[str, int] = {"received": 0, "sent_back": 1, "in_field": 2, "endorsed": 3}
GEOPOINT = re.compile(r"^(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?) -?\d+(?:\.\d+)? (\d+(?:\.\d+)?)$")


@dataclass(frozen=True)
class MissionRow:
    id: str
    title: str
    country: str | None
    sector: str | None
    project_ref: str | None
    status: Status
    risk_now: str | None
    risk_before: str | None
    red_flags: int
    sentences: int
    received_at: float | None
    approved_at: float | None
    points: list[tuple[float, float, float]] = field(default_factory=list)  # lat, lon, accuracy (m)


@dataclass(frozen=True)
class Portfolio:
    rows: list[MissionRow]
    to_review: int
    red_flags: int
    endorsed: int


def _section(conn: psycopg.Connection, mission_id: str, path: str) -> dict:
    """A section of the mission's newest pack, as JSON; empty when there is none."""
    row = conn.execute(
        "SELECT f.data FROM pack_contents c JOIN pack_files f ON f.sha256 = c.sha256"
        " WHERE c.mission_id = %s AND c.path = %s ORDER BY c.version DESC LIMIT 1",
        [mission_id, path],
    ).fetchone()
    if row is None:
        return {}
    try:
        found = json.loads(bytes(row[0]))
    except ValueError:
        return {}
    return found if isinstance(found, dict) else {}


def _points(conn: psycopg.Connection, mission_id: str) -> list[tuple[float, float, float]]:
    """Every geopoint answer in the finished walk's file(s): latitude, longitude, accuracy."""
    rows = conn.execute(
        "SELECT f.data FROM evidence_files f JOIN evidence e ON e.mission_id = f.mission_id"
        " AND e.seq = f.seq WHERE f.mission_id = %s AND e.kind = 'walk' ORDER BY f.seq",
        [mission_id],
    ).fetchall()
    points = []
    for (data,) in rows:
        try:
            answers = json.loads(bytes(data)).get("answers", {})
        except (ValueError, AttributeError):
            continue
        for value in answers.values() if isinstance(answers, dict) else []:
            found = GEOPOINT.match(value) if isinstance(value, str) else None
            if found:
                points.append((float(found[1]), float(found[2]), float(found[3])))
    return points


class DashboardData:
    def __init__(self, pool: ConnectionPool):
        self._pool = pool

    def portfolio(self, manager_id: str) -> Portfolio:
        with as_manager(self._pool, manager_id) as conn:
            missions = conn.execute("SELECT id, title FROM missions ORDER BY title").fetchall()
            rows = [self._row(conn, mission_id, title) for mission_id, title in missions]
        rows.sort(key=lambda row: (ORDER[row.status], row.title))
        return Portfolio(
            rows=rows,
            to_review=sum(row.status == "received" for row in rows),
            red_flags=sum(row.red_flags for row in rows),
            endorsed=sum(row.status == "endorsed" for row in rows),
        )

    def _row(self, conn: psycopg.Connection, mission_id: str, title: str) -> MissionRow:
        project = _section(conn, mission_id, "sections/project.json")
        risk = _section(conn, mission_id, "sections/ratings.json").get("overallRisk", {})
        report = conn.execute(
            "SELECT received_at, approved_at FROM reports WHERE mission_id = %s", [mission_id]
        ).fetchone()
        counts = conn.execute(
            "SELECT (SELECT count(*) FROM report_sentences WHERE mission_id = %s),"
            " (SELECT count(*) FROM facts WHERE mission_id = %s AND rule_id = 'red-flag')",
            [mission_id, mission_id],
        ).fetchone()
        sentences, flags = counts if counts else (0, 0)
        return MissionRow(
            id=mission_id, title=project.get("title") or title, country=project.get("country"),
            sector=project.get("sector"), project_ref=project.get("projectRef"),
            status="received" if report else "in_field",
            risk_now=risk.get("current") if isinstance(risk, dict) else None,
            risk_before=risk.get("previous") if isinstance(risk, dict) else None,
            red_flags=flags, sentences=sentences,
            received_at=report[0] if report else None, approved_at=report[1] if report else None,
            points=_points(conn, mission_id),
        )  # fmt: skip

    def project(self, manager_id: str, mission_id: str) -> "page.ProjectView | None":
        """The project page's view of one mission of the organization, or None (#176)."""
        with as_manager(self._pool, manager_id) as conn:
            found = conn.execute(
                "SELECT title FROM missions WHERE id = %s", [mission_id]
            ).fetchone()
            if found is None:
                return None
            row = self._row(conn, mission_id, found[0])
            project = _section(conn, mission_id, "sections/project.json")
            rated = _section(conn, mission_id, "sections/ratings.json")
            return page.ProjectView(
                row=row, facts=page.facts(project),
                objective=str(project.get("developmentObjective", "")),
                financing=page.financing(_section(conn, mission_id, "sections/financing.json")),
                components=page.components(_section(conn, mission_id, "sections/components.json")),
                ratings=page.ratings(rated), ratings_as_of=page.day(rated.get("asOf")),
                reports=page.reports(conn, mission_id, row.status),
            )  # fmt: skip

    def report(self, manager_id: str, mission_id: str) -> "paper.ReportView | None":
        """The approved report of one mission, rebuilt for the report page, or None (#177)."""
        with as_manager(self._pool, manager_id) as conn:
            found = conn.execute(
                "SELECT title FROM missions WHERE id = %s", [mission_id]
            ).fetchone()
            stored = read_report(conn, mission_id) if found else None
            if found is None or stored is None:
                return None
            known = paper.facts(conn, mission_id)
            rated = _section(conn, mission_id, "sections/ratings.json")
            return paper.ReportView(
                row=self._row(conn, mission_id, found[0]),
                ratings=page.ratings(rated), ratings_as_of=page.day(rated.get("asOf")),
                actions=paper.seen_for(_section(conn, mission_id, "sections/agreed-actions.json"),
                                       list(known.values())),
                lines=paper.lines(stored, known), stored=stored,
            )  # fmt: skip

    def evidence_file(self, manager_id: str, mission_id: str, seq: int) -> "paper.KeptFile | None":
        """A file the phone sent for the report's proof, or None (#177, step 8.7.2)."""
        with as_manager(self._pool, manager_id) as conn:
            return paper.kept_file(conn, mission_id, seq)
