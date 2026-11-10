"""A manager's decision on a report (#178, steps 8.8.1-8.8.2): endorse it with the passkey (Touch
ID), or send it back to the officer with a note. Only the newest version, received, verified again
(sync_checks.verify_stored), not yet decided, and never by a manager on the mission's own team
(separation of duties; Postgres refuses it too). The dashboard's own pages call these: same Origin,
the manager's session. Every decision is final and audited."""

import time
from typing import Any
from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import RedirectResponse

from missioncopilot_backend.approval_keys import ApprovalKeyStore
from missioncopilot_backend.auth import audit
from missioncopilot_backend.dashboard_auth import DashboardUser
from missioncopilot_backend.dashboard_layout import reader
from missioncopilot_backend.dashboard_routes import require_manager, same_origin
from missioncopilot_backend.db.dashboard_report import ReportView
from missioncopilot_backend.db.reviews import Decided, NotAllowed, Reviews, approval_hash
from missioncopilot_backend.errors import problem
from missioncopilot_backend.models import StrictModel
from missioncopilot_backend.passkeys import (
    PasskeyRefused,
    Site,
    endorse_options,
    verify_endorsement,
)
from missioncopilot_backend.sync_checks import verify_stored

router = APIRouter(prefix="/v1/dashboard/missions")
NOTE_LIMIT = 500


class Endorsement(StrictModel):
    credential: dict[str, Any]


class Undecidable(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code


def decider(request: Request, org_id: str) -> Reviews:
    """Where decisions are written: a test may set app.state.dashboard_decider."""
    made = getattr(request.app.state, "dashboard_decider", None)
    if made is not None:
        return made(org_id)
    databases = request.app.state.databases
    found = databases.reviews_for(org_id) if databases is not None else None
    if found is None:
        raise HTTPException(404)
    return found


def decidable(request: Request, user: DashboardUser, mission_id: str) -> tuple[ReportView, str]:
    """The newest report, if this manager may decide on it now, and the subject the endorse
    challenge names: mission, version and the approval's SHA-256."""
    view = reader(request, user.org_id).report(user.user_id, mission_id)
    if view is None:
        raise HTTPException(404)
    if view.on_team:
        raise Undecidable(403, "review:on_the_team")
    if view.decision is not None:
        raise Undecidable(409, "review:already_decided")
    keys: ApprovalKeyStore = request.app.state.approval_keys
    stored = view.stored
    if not verify_stored(stored, mission_id, keys.find(stored.device_id, stored.approval_key_id)):
        raise Undecidable(409, "review:not_verified")
    return view, f"{mission_id}:{stored.version}:{approval_hash(stored.approval_payload)}"


@router.post("/{missionId}/endorse/options", response_model=None)
def options(
    missionId: str,
    request: Request,
    user: DashboardUser = Depends(require_manager),  # first: no session is 401
    here: Site = Depends(same_origin),
) -> Response:
    try:
        _, subject = decidable(request, user, missionId)
    except Undecidable as why:
        return problem(why.status, why.code)
    made = endorse_options(request.app.state.dashboard, here, user, subject)
    return Response(made, media_type="application/json")


@router.post("/{missionId}/endorse", status_code=201, response_model=None)
def endorse(
    missionId: str,
    body: Endorsement,
    request: Request,
    user: DashboardUser = Depends(require_manager),  # first: no session is 401
    here: Site = Depends(same_origin),
) -> Response | dict[str, object]:
    try:
        view, subject = decidable(request, user, missionId)
        assertion = verify_endorsement(request.app.state.dashboard, body.credential, here, user,
                                       subject)  # fmt: skip
        decider(request, user.org_id).decide(
            user.user_id, user.name, missionId, view.stored.version, "endorsed", None,
            subject.rsplit(":", 1)[1], time.time(), assertion,
        )  # fmt: skip
    except Undecidable as why:
        return problem(why.status, why.code)
    except PasskeyRefused:
        raise HTTPException(401) from None
    except Decided:
        return problem(409, "review:already_decided")
    except NotAllowed:
        return problem(403, "review:on_the_team")
    audit(request, "report_endorsed", user.org_id, user.user_id, subject=missionId)
    return {"decision": "endorsed", "version": view.stored.version}


@router.post("/{missionId}/send-back", response_model=None)
async def send_back(
    missionId: str,
    request: Request,
    user: DashboardUser = Depends(require_manager),  # first: no session is 401
    here: Site = Depends(same_origin),
) -> Response:
    """The report page's form: a note of 1 to 500 characters, then back to the report."""
    form = parse_qs((await request.body()).decode("utf-8", "replace"), max_num_fields=4)
    note = (form.get("note") or [""])[0].strip()
    if not 1 <= len(note) <= NOTE_LIMIT:
        return problem(422, "review:note_1_to_500")
    try:
        view, subject = decidable(request, user, missionId)
        decider(request, user.org_id).decide(
            user.user_id, user.name, missionId, view.stored.version, "sent_back", note,
            subject.rsplit(":", 1)[1], time.time(),
        )  # fmt: skip
    except Undecidable as why:
        return problem(why.status, why.code)
    except Decided:
        return problem(409, "review:already_decided")
    except NotAllowed:
        return problem(403, "review:on_the_team")
    audit(request, "report_sent_back", user.org_id, user.user_id, subject=missionId)
    return RedirectResponse(f"/dashboard/missions/{missionId}/report", status_code=303)


def review_routes() -> list[APIRouter]:
    return [router]
