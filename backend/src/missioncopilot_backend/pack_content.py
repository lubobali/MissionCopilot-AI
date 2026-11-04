"""The files of a mission pack, built from the demo dataset (#89). One source: the story lives in
docs/demo/kandor-rural-roads.json and its tests guard it; this only shapes it into the files the
phone downloads. Field names follow the supervision data staff already know (ratings, results,
disbursement) and OC4IDS for the project, contract, milestones and locations.

Every file is stable bytes (sorted keys, two-space indent, one newline at the end), so the same data
always gives the same files and the same manifest."""

import json
from datetime import date

from missioncopilot_backend.checklist_check import check_form, contract

SECTIONS = (
    "project", "components", "ratings", "results", "financing", "contracts", "milestones",
    "safeguards", "agreed-actions",
)  # fmt: skip
FICTIONAL = "Fictional: Kandor is not a real country; every name and amount is invented."


def _json(body: object) -> bytes:
    return (json.dumps(body, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def milestone_status(milestone: dict, as_of: date) -> str:
    """OC4IDS milestone status: met, notMet (due and not met) or scheduled."""
    if milestone["dateMet"]:
        return "met"
    return "notMet" if date.fromisoformat(milestone["dueDate"]) < as_of else "scheduled"


def _sections(data: dict, as_of: date) -> dict[str, object]:
    mission, pack = data["mission"], data["pack"]
    sup, currency = pack["supervision"], pack["currency"]
    disbursed = sum(c["disbursed"] for c in sup["components"])
    financing = sup["financing"]
    contract = sup["contract"] | {
        "supplier": pack["contractor"],
        "contractValue": pack["contractValue"],
        "contractPeriod": pack["contractPeriod"],
        "paymentApprover": pack["paymentApprover"],
        "payments": pack["payments"],
        "physicalProgress": pack["physicalProgress"],
    }
    milestones = [
        {"id": f"M{n}", **m, "status": milestone_status(m, as_of)}
        for n, m in enumerate(pack["milestones"], start=1)
    ]
    return {
        "project": sup["project"]
        | {"title": mission["project"], "site": mission["site"], "budget": pack["budget"]}
        | {"currency": currency, "note": FICTIONAL},
        "components": {"currency": currency, "components": sup["components"]},
        "ratings": sup["ratings"],
        "results": {"indicators": sup["results"]},
        "financing": financing
        | {"currency": currency, "disbursed": disbursed}
        | {"undisbursed": financing["revised"] - financing["cancelled"] - disbursed},
        "contracts": {"currency": currency, "contracts": [contract]},
        "milestones": {"asOf": as_of.isoformat(), "milestones": milestones}
        | {"locations": sup["locations"]},
        "safeguards": sup["safeguards"],
        "agreed-actions": sup["agreedActions"] | {"summary": pack["lastReportSummary"]},
    }


def _road_checklist(pack: dict) -> dict:
    """KoBoToolbox's flat JSON for a form: survey, choices and settings rows (#93 reads it)."""
    checklist = pack["checklist"]
    return {k: checklist[k] for k in ("survey", "choices", "settings")}


def _aide_memoire(pack: dict) -> str:
    sup = pack["supervision"]
    rows = "\n".join(
        f"| {a['action']} | {a['responsible']} | {a['deadline']} | {a['status']} |"
        for a in sup["agreedActions"]["actions"]
    )
    ratings = sup["ratings"]
    return (
        f"# Aide-memoire: {sup['agreedActions']['mission']}\n\n{FICTIONAL}\n\n"
        f"{pack['lastReportSummary']}\n\n"
        f"Implementation progress: {ratings['implementationProgress']['current']}. "
        f"Overall risk: {ratings['overallRisk']['current']}.\n\n"
        "## Agreed actions\n\n| Action | Responsible | Deadline | Status |\n|---|---|---|---|\n"
        f"{rows}\n"
    )


def _progress_report(data: dict) -> str:
    report = next(d for d in data["documents"] if d["kind"] == "progress_report")
    fields = report["fields"]
    return (
        f"# {report['title']}\n\n{FICTIONAL}\n\n"
        f"- Road completed: {fields['kmCompleted']} of {fields['kmTotal']} km\n"
        f"- Section 3 bridge: {fields['bridgeSection3']}\n"
        f"- Planned completion: {fields['plannedCompletion']}\n"
        f"- Reason given for delay: {fields['reasonGiven']}\n"
    )


def pack_files(data: dict, checklist: dict | None = None) -> dict[str, bytes]:
    """Every file of the mission's pack by its path in the pack, as of the mission's start; with
    `checklist`, an admin's form (checklist_xlsx) in place of the dataset's."""
    as_of = date.fromisoformat(data["mission"]["startDate"])
    files = {f"sections/{name}.json": _json(body) for name, body in _sections(data, as_of).items()}
    files["forms/road-checklist.json"] = _json(checklist or _road_checklist(data["pack"]))
    files["documents/aide-memoire-2026-05.md"] = _aide_memoire(data["pack"]).encode()
    files["documents/progress-report-2026-09.md"] = _progress_report(data).encode()
    return files


def check_pack_files(files: dict[str, bytes]) -> None:
    """Every section and the checklist against the pack's contract, and the checklist as the phone
    checks it, before anything is published (#93: a pack the phones would refuse never goes out)."""
    for path, body in sorted(files.items()):
        if not path.endswith(".json"):
            continue
        document = json.loads(body)
        if path.startswith("forms/"):
            check_form(document)
        elif not contract(path.removeprefix("sections/").removesuffix(".json")).is_valid(document):
            raise ValueError(f"{path} does not match the pack's contract")
