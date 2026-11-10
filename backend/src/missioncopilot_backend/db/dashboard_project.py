"""The project page's data (#176, step 8.6.1): the pack's header, financing, components and ratings,
and the mission's reports, read as a manager. Ratings keep their own scale: performance (Highly
Satisfactory to Highly Unsatisfactory) gets better or worse; risk (Low to High) goes up or down,
which for the reader is better or worse too. The pack holds a current and a previous value only, so
that is the history shown."""

from dataclasses import dataclass
from datetime import date
from typing import TYPE_CHECKING, Literal

import psycopg

if TYPE_CHECKING:
    from missioncopilot_backend.db.dashboard_data import MissionRow

Trend = Literal["better", "worse", "same", "unknown"]
PERFORMANCE = ["Highly Unsatisfactory", "Unsatisfactory", "Moderately Unsatisfactory",
               "Moderately Satisfactory", "Satisfactory", "Highly Satisfactory"]  # fmt: skip
RISK = ["High", "Substantial", "Moderate", "Low"]  # best last, as for performance
AREAS = [
    ("pdoProgress", "Progress toward the objective"),
         ("implementationProgress", "Implementation progress"),
         ("financialManagement", "Financial management"), ("procurement", "Procurement"),
         ("environmentalSocial", "Environmental and social"), ("overallRisk", "Overall risk"),
]  # fmt: skip


@dataclass(frozen=True)
class Rating:
    area: str
    before: str | None
    now: str | None
    trend: Trend


@dataclass(frozen=True)
class Financing:
    total: int
    disbursed: int
    currency: str

    @property
    def percent(self) -> int:
        return round(100 * self.disbursed / self.total) if self.total else 0


@dataclass(frozen=True)
class Component:
    name: str
    cost: int
    disbursed: int


@dataclass(frozen=True)
class ReportEntry:
    draft_id: str
    status: str
    approved_at: float
    received_at: float


@dataclass(frozen=True)
class ProjectView:
    row: "MissionRow"
    facts: dict[str, str]
    objective: str
    financing: Financing | None
    components: list[Component]
    ratings: list[Rating]
    ratings_as_of: str | None
    reports: list[ReportEntry]


def day(text: object) -> str | None:
    try:
        return date.fromisoformat(str(text)).strftime("%-d %b %Y")
    except ValueError:
        return None


def trend(scale: list[str], before: object, now: object) -> Trend:
    if (
        not isinstance(before, str)
        or not isinstance(now, str)
        or before not in scale
        or now not in scale
    ):
        return "unknown"
    step = scale.index(now) - scale.index(before)
    return "better" if step > 0 else "worse" if step < 0 else "same"


def ratings(found: dict) -> list[Rating]:
    out = []
    for key, area in AREAS:
        value = found.get(key)
        if not isinstance(value, dict):
            continue
        scale = RISK if key == "overallRisk" else PERFORMANCE
        before, now = value.get("previous"), value.get("current")
        out.append(Rating(area, before, now, trend(scale, before, now)))
    return out


def financing(found: dict) -> Financing | None:
    total, disbursed = found.get("revised") or found.get("original"), found.get("disbursed")
    if not isinstance(total, int) or not isinstance(disbursed, int):
        return None
    return Financing(total, disbursed, str(found.get("currency", "")))


def components(found: dict) -> list[Component]:
    items = found.get("components", [])
    return [Component(str(c.get("name", "")), int(c.get("cost", 0)), int(c.get("disbursed", 0)))
            for c in items if isinstance(c, dict)] if isinstance(items, list) else []  # fmt: skip


def facts(project: dict) -> dict[str, str]:
    pairs = [
        ("Reference", project.get("projectRef")), ("Country", project.get("country")),
        ("Sector", project.get("sector")),
        ("Implementing agency", project.get("implementingAgency")),
        ("Status", str(project.get("status", "")).capitalize() or None),
        ("Approved", day(project.get("approvalDate"))),
        ("Closing", day(project.get("closingDate"))),
    ]  # fmt: skip
    return {label: str(value) for label, value in pairs if value}


def reports(conn: psycopg.Connection, mission_id: str, status: str) -> list[ReportEntry]:
    """Every version, newest first, each with its own decision (#178), else `status`."""
    rows = conn.execute(
        "SELECT r.draft_id, r.approved_at, r.received_at, v.decision FROM reports r"
        " LEFT JOIN report_reviews v ON v.mission_id = r.mission_id AND v.version = r.version"
        " WHERE r.mission_id = %s ORDER BY r.version DESC",
        [mission_id],
    ).fetchall()
    return [ReportEntry(draft, decision or status, approved, received)
            for draft, approved, received, decision in rows]  # fmt: skip
