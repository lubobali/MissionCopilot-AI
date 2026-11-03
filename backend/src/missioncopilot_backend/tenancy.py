"""Organization isolation (threat model T31, ADR 0008). Each organization has its own database
(db/organizations.py). A route gets only the store of the organization in the caller's token, and a
store has no way to reach another organization's data, so a cross-organization read cannot be
written by mistake. Inside an organization a caller sees only the missions on their team. Another
team's or organization's mission answers exactly like a missing one: a caller cannot even learn
that it exists."""

from dataclasses import dataclass
from typing import Protocol

from fastapi import Depends, HTTPException, Request

from missioncopilot_backend.auth import Principal, audit, require_principal


@dataclass(frozen=True)
class Mission:
    id: str
    org_id: str
    title: str


class MissionReader(Protocol):
    """One organization's missions, read as one user: only missions on that user's team."""

    org_id: str

    def get(self, user_id: str, mission_id: str) -> Mission | None: ...
    def for_user(self, user_id: str) -> list[Mission]: ...


class OrgStores(Protocol):
    def for_org(self, org_id: str) -> MissionReader | None: ...


class MissionStore:
    """One organization's missions and teams, in memory, for tests. The server reads them from the
    organization's own database, where Postgres row-level security does the team check
    (db/missions.py); tests/db/test_mission_store.py runs one contract on both."""

    def __init__(self, org_id: str):
        self.org_id = org_id
        self._missions: dict[str, Mission] = {}
        self._teams: dict[str, set[str]] = {}

    def add(self, mission: Mission, team: tuple[str, ...] = ()) -> None:
        if mission.org_id != self.org_id:
            raise ValueError(f"store of {self.org_id} refuses a mission of {mission.org_id}")
        if "" in team:
            raise ValueError("a team member needs a user id")
        self._missions[mission.id] = mission
        self._teams[mission.id] = set(team)

    def get(self, user_id: str, mission_id: str) -> Mission | None:
        on_team = user_id in self._teams.get(mission_id, set())
        return self._missions[mission_id] if on_team else None

    def for_user(self, user_id: str) -> list[Mission]:
        mine = [m for m in self._missions.values() if user_id in self._teams[m.id]]
        return sorted(mine, key=lambda m: m.id)


class OrgDatabases:
    """One store per organization, in memory, for tests; there is no store that spans them."""

    def __init__(self) -> None:
        self._stores: dict[str, MissionStore] = {}

    def create(self, org_id: str) -> MissionStore:
        store = self._stores[org_id] = MissionStore(org_id)
        return store

    def for_org(self, org_id: str) -> MissionStore | None:
        return self._stores.get(org_id)


@dataclass(frozen=True)
class CallerMissions:
    """The caller's own view: their organization's missions, as them. Routes only ever get this, so
    no route can read a mission without the team check."""

    store: MissionReader
    user_id: str

    @property
    def org_id(self) -> str:
        return self.store.org_id

    def get(self, mission_id: str) -> Mission | None:
        return self.store.get(self.user_id, mission_id)

    def mine(self) -> list[Mission]:
        return self.store.for_user(self.user_id)


NOT_FOUND = HTTPException(404)


def org_store(
    request: Request, principal: Principal = Depends(require_principal)
) -> CallerMissions:
    """The caller's organization and user, both from the token only. No database for the
    organization: 404, not 403."""
    databases: OrgStores | None = getattr(request.app.state, "databases", None)
    store = databases.for_org(principal.org_id) if databases else None
    if store is None:
        audit(request, "org_without_database", org_id=principal.org_id, actor=principal.user_id)
        raise NOT_FOUND
    return CallerMissions(store, principal.user_id)


def mission_or_404(missions: CallerMissions, mission_id: str) -> Mission:
    """Another team's mission, another organization's and a missing one all give the same 404."""
    mission = missions.get(mission_id)
    if mission is None:
        raise NOT_FOUND
    return mission
