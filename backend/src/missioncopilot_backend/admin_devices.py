"""Operator commands for phones (#90): issue a one-time code, list, approve and revoke phones, until
the dashboard and its manager logins exist (Phase 8). The same rules as the manager routes
(device_routes): an operator never approves a phone of their own, a revoked phone stays revoked, and
every action is in the audit log, with the operator named and never a code."""

from datetime import UTC, datetime
from pathlib import Path

from missioncopilot_backend.admin_common import AdminError, as_admin, directory_url
from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.devices import Device


def _open(admin_url: str, address_dir: Path):
    return Directory.open(as_admin(admin_url, directory_url(address_dir)), migrations=False)


def issue_code(
    admin_url: str, address_dir: Path, org_id: str, user_id: str, label: str
) -> tuple[str, str]:
    """A one-time code for one person's phone in one organization: (code, expiry as UTC time)."""
    with _open(admin_url, address_dir) as directory:
        if org_id not in directory.organizations():
            raise AdminError(f"no organization {org_id} in the directory")
        code, grant = directory.codes.issue(org_id, user_id, label)
        directory.audit.record("enrollment_code_issued", org_id=org_id, actor="operator:cli")
    expires = datetime.fromtimestamp(grant.expires_at, UTC).strftime("%Y-%m-%d %H:%M UTC")
    return code, expires


def list_devices(admin_url: str, address_dir: Path, org_id: str) -> list[Device]:
    with _open(admin_url, address_dir) as directory:
        return directory.devices.of_org(org_id)


def _phone(directory: Directory, device_id: str) -> Device:
    device = directory.devices.find(device_id)
    if device is None:
        raise AdminError(f"no phone {device_id}")
    return device


def approve(admin_url: str, address_dir: Path, device_id: str, by: str) -> Device:
    with _open(admin_url, address_dir) as directory:
        device = _phone(directory, device_id)
        if device.user_id == by:
            raise AdminError("an operator never approves their own phone; ask another operator")
        if device.status != "pending":
            raise AdminError(f"this phone is {device.status}; a revoked phone stays revoked")
        device = directory.devices.update(device, status="active")
        directory.audit.record("device_approved", org_id=device.org_id, actor=f"operator:{by}",
                               subject=device.id)  # fmt: skip
    return device


def revoke(admin_url: str, address_dir: Path, device_id: str, by: str) -> Device:
    """Its next signed request gets a signed shred order (ADR 0012)."""
    with _open(admin_url, address_dir) as directory:
        device = directory.devices.update(_phone(directory, device_id), status="revoked")
        directory.audit.record("device_revoked", org_id=device.org_id, actor=f"operator:{by}",
                               subject=device.id)  # fmt: skip
    return device
