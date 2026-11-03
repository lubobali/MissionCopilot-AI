"""Operator commands for phones (#90), until the dashboard and its manager logins exist (Phase 8):
issue a one-time code, list, approve and revoke phones. Same rules as the manager routes: never
approve a phone of your own, a revoked phone stays revoked, everything goes into the audit log."""

import uuid
from collections.abc import Generator
from dataclasses import dataclass
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from missioncopilot_backend import admin, admin_devices
from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.organizations import drop_database, drop_organization
from missioncopilot_backend.devices import enroll
from tests.db.postgres import admin_url

pytestmark = pytest.mark.db


@dataclass
class Ops:
    secrets: Path
    directory: str
    org_id: str

    def env(self) -> dict[str, str]:
        return {
            "MISSIONCOPILOT_ADMIN_URL": admin_url(),
            "MISSIONCOPILOT_ADDRESS_DIR": str(self.secrets),
            "MISSIONCOPILOT_DIRECTORY_DB": self.directory,
        }

    def directory_admin(self) -> str:
        return make_conninfo(admin_url(), dbname=self.directory)


@pytest.fixture
def ops(tmp_path) -> Generator[Ops]:
    directory = f"mc_dir_{uuid.uuid4().hex[:12]}"
    org_id = f"t-{uuid.uuid4().hex[:12]}"
    found = Ops(tmp_path / "addresses", directory, org_id)
    admin.setup(admin_url(), found.secrets, directory)
    admin.add_org(admin_url(), found.secrets, org_id)
    try:
        yield found
    finally:
        drop_organization(admin_url(), org_id)
        drop_database(admin_url(), directory, f"{directory}_owner", f"{directory}_app")


def _enroll_phone(ops: Ops, user: str = "officer-7") -> str:
    """A phone enrolls with a code from issue_code, as the app does."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    from missioncopilot_backend.devices import enrollment_message

    code, _ = admin_devices.issue_code(admin_url(), ops.secrets, ops.org_id, user, f"{user} iPhone")
    key = ec.generate_private_key(ec.SECP256R1())
    der = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    proof = key.sign(enrollment_message(code, der), ec.ECDSA(hashes.SHA256()))
    with Directory.open(ops.directory_admin(), migrations=False) as directory:
        device = enroll(directory.codes, directory.devices, code, der, proof)
    assert device is not None
    return device.id


def _audit(ops: Ops) -> list[tuple]:
    with psycopg.connect(ops.directory_admin()) as conn:
        return conn.execute(
            "SELECT kind, org_id, actor, subject FROM audit_events ORDER BY seq"
        ).fetchall()


def test_an_issued_code_enrolls_one_phone_once(ops):
    device_id = _enroll_phone(ops)

    phones = admin_devices.list_devices(admin_url(), ops.secrets, ops.org_id)
    assert [(p.id, p.user_id, p.status) for p in phones] == [(device_id, "officer-7", "pending")]


def test_an_operator_approves_a_pending_phone_and_it_is_recorded(ops):
    device_id = _enroll_phone(ops)

    approved = admin_devices.approve(admin_url(), ops.secrets, device_id, by="ops-lead")

    assert approved.status == "active"
    assert ("device_approved", ops.org_id, "operator:ops-lead", device_id) in _audit(ops)


def test_an_operator_never_approves_their_own_phone(ops):
    device_id = _enroll_phone(ops, user="ops-lead")

    with pytest.raises(admin.AdminError, match="own phone"):
        admin_devices.approve(admin_url(), ops.secrets, device_id, by="ops-lead")


def test_a_revoked_phone_stays_revoked(ops):
    device_id = _enroll_phone(ops)
    admin_devices.revoke(admin_url(), ops.secrets, device_id, by="ops-lead")

    with pytest.raises(admin.AdminError, match="revoked"):
        admin_devices.approve(admin_url(), ops.secrets, device_id, by="ops-lead")
    assert ("device_revoked", ops.org_id, "operator:ops-lead", device_id) in _audit(ops)


def test_an_unknown_phone_is_an_error(ops):
    with pytest.raises(admin.AdminError, match="no phone"):
        admin_devices.approve(admin_url(), ops.secrets, str(uuid.uuid4()), by="ops-lead")


def test_issuing_a_code_is_recorded_without_the_code(ops):
    code, _ = admin_devices.issue_code(admin_url(), ops.secrets, ops.org_id, "officer-7", "phone")

    events = _audit(ops)
    assert ("enrollment_code_issued", ops.org_id, "operator:cli", None) in events
    assert code not in str(events)


def test_a_code_for_an_unknown_organization_is_refused(ops):
    with pytest.raises(admin.AdminError, match="no organization"):
        admin_devices.issue_code(admin_url(), ops.secrets, "t-nobody", "officer-7", "phone")


def test_the_command_line_prints_the_code_once_and_approves(ops, capsys):
    env = ops.env()

    assert (
        admin.main(["issue-code", ops.org_id, "officer-7", "--label", "Officer 7 iPhone"], env) == 0
    )
    out = capsys.readouterr().out
    assert "one-time code" in out and "15 minutes" in out
    device_id = _enroll_phone(ops)
    assert admin.main(["list-devices", ops.org_id], env) == 0
    assert device_id in capsys.readouterr().out
    assert admin.main(["approve-device", device_id, "--by", "ops-lead"], env) == 0
    assert admin.main(["revoke-device", device_id, "--by", "ops-lead"], env) == 0
    assert admin.main(["approve-device", device_id, "--by", "ops-lead"], env) == 1
    assert "revoked" in capsys.readouterr().err
