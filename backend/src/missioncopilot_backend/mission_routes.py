"""A phone's own missions (API contract listMyMissions, #92): the caller's team missions in the
phone's own organization, each with its newest pack or none, so the phone can show what is ready
for offline before it downloads anything. The organization and user come from the enrolled phone,
never from the request; Postgres row-level security decides which missions and packs it sees. An
organization without a database answers 404, as the pack routes do."""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request

from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device

router: APIRouter = device_router()


def _when(moment: datetime) -> str:
    return moment.isoformat().replace("+00:00", "Z")


@router.get("/missions")
def list_my_missions(
    request: Request, device: DevicePrincipal = Depends(require_device)
) -> dict[str, object]:
    databases = getattr(request.app.state, "databases", None)
    store = databases.for_org(device.org_id) if databases else None
    if store is None:
        raise HTTPException(404)
    missions = store.for_user(device.user_id)
    packs_for = getattr(databases, "packs_for", None)
    packs = packs_for(device.org_id) if packs_for else None
    newest = packs.newest_summaries(device.user_id, [m.id for m in missions]) if packs else {}
    listed = []
    for mission in missions:
        pack = newest.get(mission.id)
        summary = None
        if pack:
            summary = {"version": pack.version, "createdAt": _when(pack.created_at),
                       "expiresAt": _when(pack.expires_at)}  # fmt: skip
        listed.append({"id": mission.id, "title": mission.title, "pack": summary})
    return {"orgId": device.org_id, "missions": listed}


def mission_routes() -> list[APIRouter]:
    return [router]
