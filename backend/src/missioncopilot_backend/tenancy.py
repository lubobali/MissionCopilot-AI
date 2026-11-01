"""Organization isolation (threat model T31, ADR 0008). Each organization has its own store,
standing in for its own database until Postgres arrives in Phase 5. A route gets only the store of
the organization in the caller's token, and a store has no way to reach another organization's
data, so a cross-organization read cannot be written by mistake. Another organization's mission
answers exactly like a missing one: a caller cannot even learn that it exists."""

from dataclasses import dataclass

from fastapi import Depends, HTTPException, Request

from missioncopilot_backend.auth import Principal, require_principal


@dataclass(frozen=True)
class Mission:
    id: str
    org_id: str
    title: str


class MissionStore:
    """One organization's missions."""

    def __init__(self, org_id: str):
        self.org_id = org_id
        self._missions: dict[str, Mission] = {}

    def add(self, mission: Mission) -> None:
        if mission.org_id != self.org_id:
            raise ValueError(f"store of {self.org_id} refuses a mission of {mission.org_id}")
        self._missions[mission.id] = mission

    def get(self, mission_id: str) -> Mission | None:
        return self._missions.get(mission_id)


class OrgDatabases:
    """One store per organization; there is no store that spans organizations."""

    def __init__(self) -> None:
        self._stores: dict[str, MissionStore] = {}

    def create(self, org_id: str) -> MissionStore:
        store = self._stores[org_id] = MissionStore(org_id)
        return store

    def for_org(self, org_id: str) -> MissionStore | None:
        return self._stores.get(org_id)


NOT_FOUND = HTTPException(404)


def org_store(request: Request, principal: Principal = Depends(require_principal)) -> MissionStore:
    """The caller's organization's store, from the token only. No database for it: 404, not 403."""
    databases: OrgDatabases | None = getattr(request.app.state, "databases", None)
    store = databases.for_org(principal.org_id) if databases else None
    if store is None:
        raise NOT_FOUND
    return store


def mission_or_404(store: MissionStore, mission_id: str) -> Mission:
    mission = store.get(mission_id)
    if mission is None:
        raise NOT_FOUND
    return mission
