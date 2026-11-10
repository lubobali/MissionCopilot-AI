"""The rest of the fictional Kandor portfolio (Lubo, Nov 10): five more projects so the dashboard
shows what a manager's portfolio looks like. Each is a real mission with a real signed pack (its
header, ratings, financing and components), checked against the pack's contract like any other;
they are in the field, with no report yet. Their teams are fictional officers with no phone, so no
phone ever downloads them. Every name and amount is invented."""

import json

import psycopg
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.db.packs import publish_pack
from missioncopilot_backend.pack_content import check_pack_files

TEAM = "officer-9"  # fictional, no phone enrolled
P = ["Highly Unsatisfactory", "Unsatisfactory", "Moderately Unsatisfactory",
     "Moderately Satisfactory", "Satisfactory", "Highly Satisfactory"]  # fmt: skip
# id suffix, ref, title, sector, agency, objective, (risk before, now), performance (before, now),
# (total, disbursed), components
PROJECTS = [
    ("3", "KWSS-P2", "Kandor Water Supply and Sanitation", "Water: urban supply",
     "Kandor Water Authority", "Give safe piped water to 180,000 people in three towns.",
     ("Substantial", "Moderate"), (2, 4), (18_000_000, 11_700_000),
     [("Treatment plants", 9_000_000, 6_300_000), ("Networks", 7_500_000, 4_800_000),
      ("Project management", 1_500_000, 600_000)]),
    ("4", "KHCS-P1", "Kandor Primary Health Care", "Health: primary care",
     "Kandor Ministry of Health", "Bring basic health services within 5 km of rural homes.",
     ("Moderate", "Moderate"), (3, 3), (9_500_000, 4_100_000),
     [("Clinics", 6_000_000, 2_900_000), ("Staff training", 2_500_000, 900_000),
      ("Project management", 1_000_000, 300_000)]),
    ("5", "KSR-P1", "Kandor Schools Rehabilitation", "Education: school buildings",
     "Kandor Ministry of Education", "Make 240 rural schools safe and open all year.",
     ("Moderate", "Substantial"), (3, 2), (14_000_000, 8_900_000),
     [("School works", 12_000_000, 8_200_000), ("Project management", 2_000_000, 700_000)]),
    ("6", "KRE-P1", "Kandor Rural Electrification", "Energy: rural grid",
     "Kandor Power Company", "Connect 35,000 rural homes and 400 small firms to power.",
     ("Low", "Moderate"), (4, 3), (22_000_000, 6_600_000),
     [("Grid extension", 18_000_000, 5_400_000), ("Connections", 3_000_000, 900_000),
      ("Project management", 1_000_000, 300_000)]),
    ("7", "KID-P1", "Kandor Irrigation and Drainage", "Agriculture: irrigation",
     "Kandor Ministry of Agriculture", "Irrigate 12,000 hectares for small farmers all year.",
     ("High", "High"), (2, 1), (16_500_000, 13_900_000),
     [("Canals", 13_000_000, 11_800_000), ("Farmer groups", 2_500_000, 1_500_000),
      ("Project management", 1_000_000, 600_000)]),
]  # fmt: skip


def mission_id(suffix: str) -> str:
    return f"6f1d2c3a-0000-4000-8000-00000000000{suffix}"


def _files(project: tuple) -> dict[str, bytes]:
    _, ref, title, sector, agency, objective, risk, perf, money, parts = project
    rated = {k: {"previous": P[perf[0]], "current": P[perf[1]]}
             for k in ("pdoProgress", "implementationProgress", "financialManagement",
                       "procurement", "environmentalSocial")}  # fmt: skip
    rated["overallRisk"] = {"previous": risk[0], "current": risk[1]}
    sections = {
        "project": {"approvalDate": "2024-03-14", "budget": money[0], "closingDate": "2028-06-30",
                    "country": "Kandor", "currency": "USD", "developmentObjective": objective,
                    "implementingAgency": agency, "projectRef": ref, "sector": sector,
                    "note": "Fictional: Kandor is not a real country; every name and amount is "
                            "invented.", "site": f"Kandor, {sector.split(': ')[1]}",
                    "status": "implementation", "title": title},
        "ratings": {"asOf": "2026-06-30", **rated},
        "financing": {"cancelled": 0, "currency": "USD", "disbursed": money[1],
                      "loanId": ref.replace("-P", "-L"), "original": money[0],
                      "revised": money[0], "undisbursed": money[0] - money[1]},
        "components": {"currency": "USD", "components": [
            {"id": f"C{i}", "name": n, "cost": c, "disbursed": d}
            for i, (n, c, d) in enumerate(parts, start=1)]},
    }  # fmt: skip
    return {f"sections/{name}.json": json.dumps(body, sort_keys=True, indent=2).encode()
            for name, body in sections.items()}  # fmt: skip


def seed_portfolio(conn: psycopg.Connection) -> None:
    """The five missions and their fictional team; safe to run again."""
    for project in PROJECTS:
        conn.execute("INSERT INTO missions (id, title) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                     [mission_id(project[0]), project[2]])  # fmt: skip
        conn.execute("INSERT INTO mission_members VALUES (%s, %s) ON CONFLICT DO NOTHING",
                     [mission_id(project[0]), TEAM])  # fmt: skip


def publish_portfolio(url: str, org_id: str, key: ec.EllipticCurvePrivateKey) -> int:
    """Each project's pack, checked first; how many were published."""
    for project in PROJECTS:
        files = _files(project)
        check_pack_files(files)
        publish_pack(url, org_id, mission_id(project[0]), files, key)
    return len(PROJECTS)
