"""Approving and revoking phones (threat model T26). A manager approves a pending phone of their
own organization, never their own phone; a revoked phone can never be approved again; another
organization's phone answers exactly like a missing one. Every decision is recorded with the
device."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.auth import TokenVerifier
from missioncopilot_backend.devices import DeviceRegistry, EnrollmentGrant
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

ISSUER, AUDIENCE = "https://login.example.org", "missioncopilot-api"


@pytest.fixture(scope="module")
def signer() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def as_user(signer, *roles: str, org: str = "org-a", user: str = "manager-1") -> dict[str, str]:
    now = int(time.time())
    claims: dict[str, object] = {"iss": ISSUER, "aud": AUDIENCE, "sub": user, "org": org}
    claims |= {"roles": list(roles), "iat": now, "exp": now + 300}
    return {"Authorization": f"Bearer {jwt.encode(claims, signer, algorithm='ES256')}"}


def phone(devices: DeviceRegistry, org: str, user: str) -> str:
    key = ec.generate_private_key(ec.SECP256R1()).public_key()
    der = key.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return devices.add(EnrollmentGrant(org, user, f"{user} iPhone", 0.0), der).id


@pytest.fixture
def world(signer):
    devices, log = DeviceRegistry(), AuditLog()
    public = signer.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    verifier = TokenVerifier(public.decode(), issuer=ISSUER, audience=AUDIENCE)
    app = create_app(Settings(), verifier=verifier, devices=devices, audit=log)
    return local_client(app), devices, log


def approve(client, device_id: str, headers):
    return client.post(f"/v1/devices/{device_id}/approve", headers=headers)


def revoke(client, device_id: str, headers):
    return client.post(f"/v1/devices/{device_id}/revoke", headers=headers)


def test_a_manager_approves_a_pending_phone(world, signer):
    client, devices, _ = world
    device_id = phone(devices, "org-a", "officer-7")

    response = approve(client, device_id, as_user(signer, "manager"))

    assert response.json()["status"] == "active"
    assert devices.find(device_id).status == "active"


def test_only_a_pending_phone_can_be_approved(world, signer):
    client, devices, _ = world
    manager = as_user(signer, "manager")
    active, revoked = phone(devices, "org-a", "officer-7"), phone(devices, "org-a", "officer-8")
    approve(client, active, manager)
    revoke(client, revoked, manager)

    assert approve(client, active, manager).status_code == 409
    assert approve(client, revoked, manager).status_code == 409
    assert devices.find(revoked).status == "revoked"


def test_a_manager_cannot_approve_their_own_phone(world, signer):
    client, devices, _ = world
    own = phone(devices, "org-a", "manager-1")

    assert approve(client, own, as_user(signer, "manager", user="manager-1")).status_code == 403
    assert devices.find(own).status == "pending"


@pytest.mark.parametrize("roles", [["officer"], ["admin"], []])
def test_only_a_manager_approves(world, signer, roles):
    client, devices, _ = world

    assert (
        approve(client, phone(devices, "org-a", "officer-7"), as_user(signer, *roles)).status_code
        == 403
    )


def test_another_organizations_phone_looks_missing(world, signer):
    client, devices, _ = world
    theirs = phone(devices, "org-b", "officer-9")
    manager = as_user(signer, "manager", "admin")

    for action in (approve, revoke):
        cross = action(client, theirs, manager)
        missing = action(client, "00000000-0000-4000-8000-000000000000", manager)
        assert cross.status_code == missing.status_code == 404
        assert cross.json() == missing.json()
    assert devices.find(theirs).status == "pending"
    ours = phone(devices, "org-a", "officer-7")
    assert approve(client, ours, manager).status_code == 200  # the route is real, not a blanket 404


@pytest.mark.parametrize("roles", [["manager"], ["admin"]])
def test_a_manager_or_admin_revokes(world, signer, roles):
    client, devices, _ = world
    device_id = phone(devices, "org-a", "officer-7")

    assert revoke(client, device_id, as_user(signer, *roles)).json()["status"] == "revoked"


def test_an_officer_cannot_revoke(world, signer):
    client, devices, _ = world

    assert (
        revoke(client, phone(devices, "org-a", "officer-7"), as_user(signer, "officer")).status_code
        == 403
    )


def test_a_manager_lists_only_their_organizations_phones_pending_first(world, signer):
    client, devices, _ = world
    first, second = phone(devices, "org-a", "officer-1"), phone(devices, "org-a", "officer-2")
    phone(devices, "org-b", "officer-9")
    approve(client, first, as_user(signer, "manager"))

    listed = client.get("/v1/devices", headers=as_user(signer, "manager")).json()

    assert [(d["id"], d["status"]) for d in listed] == [(second, "pending"), (first, "active")]
    assert client.get("/v1/devices", headers=as_user(signer, "officer")).status_code == 403


def test_decisions_are_recorded_with_the_device(world, signer):
    client, devices, log = world
    device_id = phone(devices, "org-a", "officer-7")
    approve(client, device_id, as_user(signer, "manager"))
    revoke(client, device_id, as_user(signer, "admin", user="admin-1"))

    decisions = [(e.kind, e.org_id, e.actor, e.subject) for e in log.events() if e.subject]
    assert decisions == [
        ("device_approved", "org-a", "manager-1", device_id),
        ("device_revoked", "org-a", "admin-1", device_id),
    ]
