"""Operator command for the dashboard (#174): invite a manager. The link carries a one-time code
that works once, for 15 minutes; the manager opens it on their Mac and creates a passkey (Touch ID).
The audit log names the operator, never the code."""

from datetime import UTC, datetime
from pathlib import Path

from missioncopilot_backend.admin_common import AdminError
from missioncopilot_backend.admin_devices import _open


def invite_manager(
    admin_url: str,
    address_dir: Path,
    org_id: str,
    user_id: str,
    name: str,
    base: str,
    confidential: bool = False,
) -> tuple[str, str]:
    """(the one-time link, its expiry as UTC time). `confidential`: may also read strictly
    confidential sentences (red flags, #177)."""
    if not base.startswith("https://"):
        raise AdminError("the dashboard address must use https (passkeys need it)")
    roles = ("manager", "confidential") if confidential else ("manager",)
    with _open(admin_url, address_dir) as directory:
        if org_id not in directory.organizations():
            raise AdminError(f"no organization {org_id} in the directory")
        user = directory.dashboard.add_user(org_id, user_id, name, roles)
        code, expires_at = directory.dashboard.issue_invite(user.id)
        directory.audit.record("manager_invited", org_id=org_id, actor="operator:cli",
                               subject=user.id)  # fmt: skip
    expires = datetime.fromtimestamp(expires_at, UTC).strftime("%Y-%m-%d %H:%M UTC")
    return f"{base.rstrip('/')}/dashboard/invite/{code}", expires
