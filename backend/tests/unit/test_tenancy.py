"""Organization isolation (threat model T31, API1:2023 broken object-level authorization). Each
organization has its own store, chosen only from the caller's token; another organization's mission
answers exactly like a mission that does not exist, so a caller cannot even learn that it exists."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.auth import TokenVerifier, secured_router
from missioncopilot_backend.models import StrictModel
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.tenancy import (
    Mission,
    MissionStore,
    OrgDatabases,
    mission_or_404,
    org_store,
)
from tests.unit.clients import local_client
from tests.unit.route_listing import served_routes

pytestmark = pytest.mark.unit

ISSUER, AUDIENCE = "https://login.example.org", "missioncopilot-api"
OWN, OTHER, MISSING = "m-a1", "m-b1", "m-none"


class NoteIn(StrictModel):
    text: str


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def bearer(signer, org: str) -> dict[str, str]:
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": AUDIENCE, "sub": "u1", "org": org, "iat": now, "exp": now + 300}
    return {"Authorization": f"Bearer {jwt.encode(claims, signer, algorithm='ES256')}"}


def databases() -> OrgDatabases:
    dbs = OrgDatabases()
    dbs.create("org-a").add(Mission(id=OWN, org_id="org-a", title="Kandor roads, package 1"))
    dbs.create("org-b").add(Mission(id=OTHER, org_id="org-b", title="Another org's mission"))
    return dbs


def build_app(signer) -> FastAPI:
    public_pem = signer.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    verifier = TokenVerifier(public_pem.decode(), issuer=ISSUER, audience=AUDIENCE)
    app = create_app(Settings(), verifier=verifier, databases=databases())
    router = secured_router()

    @router.get("/test/missions/{mission_id}")
    def read(mission_id: str, store: MissionStore = Depends(org_store)) -> dict[str, str]:
        return {"title": mission_or_404(store, mission_id).title}

    @router.post("/test/missions/{mission_id}/notes")
    def add_note(
        mission_id: str, note: NoteIn, store: MissionStore = Depends(org_store)
    ) -> dict[str, str]:
        return {"mission": mission_or_404(store, mission_id).id, "note": note.text}

    app.include_router(router)
    return app


@pytest.fixture
def client(signer) -> TestClient:
    return local_client(build_app(signer))


def test_a_store_holds_only_its_own_organization():
    dbs = databases()
    store_a, store_b = dbs.for_org("org-a"), dbs.for_org("org-b")

    assert store_a is not None and store_b is not None
    assert store_a.get(OTHER) is None
    assert store_b.get(OWN) is None


def test_a_store_refuses_another_organizations_mission():
    with pytest.raises(ValueError, match="org-b"):
        MissionStore("org-a").add(Mission(id="x", org_id="org-b", title="smuggled"))


def test_an_organization_without_a_database_gets_nothing():
    assert databases().for_org("org-unknown") is None


def test_own_mission_is_readable(client, signer):
    response = client.get(f"/v1/test/missions/{OWN}", headers=bearer(signer, "org-a"))

    assert response.json() == {"title": "Kandor roads, package 1"}


def test_another_organizations_mission_looks_like_it_does_not_exist(client, signer):
    headers = bearer(signer, "org-a")
    cross = client.get(f"/v1/test/missions/{OTHER}", headers=headers)
    missing = client.get(f"/v1/test/missions/{MISSING}", headers=headers)

    assert cross.status_code == missing.status_code == 404
    assert cross.json() == missing.json()


def test_a_header_or_query_cannot_switch_organization(client, signer):
    headers = bearer(signer, "org-a") | {"X-Org": "org-b"}

    response = client.get(f"/v1/test/missions/{OTHER}", params={"org": "org-b"}, headers=headers)

    assert response.status_code == 404


def test_a_token_for_an_organization_without_a_database_gets_404(client, signer):
    response = client.get(f"/v1/test/missions/{OWN}", headers=bearer(signer, "org-unknown"))

    assert response.status_code == 404


def cross_tenant_leaks(app: FastAPI, signer) -> list[str]:
    """Every route that takes a mission id, called by org A with org B's id, must answer exactly
    like a missing id. New routes are covered automatically."""
    client, headers = local_client(app), bearer(signer, "org-a")
    leaks = []
    for route in served_routes(app):
        if "{mission_id}" not in route.path:
            continue
        body = {"text": "probe"} if route.body_types else None
        answers = [
            client.request(
                route.method, route.path.format(mission_id=mid), json=body, headers=headers
            )
            for mid in (OTHER, MISSING)
        ]
        cross, missing = answers
        if cross.status_code != 404 or cross.json() != missing.json():
            leaks.append(f"{route.method} {route.path}")
    return leaks


def test_no_route_leaks_across_organizations(signer):
    app = build_app(signer)

    assert len([r for r in served_routes(app) if "{mission_id}" in r.path]) == 2
    assert cross_tenant_leaks(app, signer) == []


def test_the_cross_tenant_guard_sees_a_leaky_route(signer):
    app = build_app(signer)
    everything = databases()
    router = secured_router()

    @router.get("/test/leaky/{mission_id}")
    def leaky(mission_id: str) -> dict[str, str]:
        for org in ("org-a", "org-b"):  # the mistake: looks in every organization
            store = everything.for_org(org)
            if store and (mission := store.get(mission_id)):
                return {"title": mission.title}
        return {}

    app.include_router(router)

    assert cross_tenant_leaks(app, signer) == ["GET /v1/test/leaky/{mission_id}"]
