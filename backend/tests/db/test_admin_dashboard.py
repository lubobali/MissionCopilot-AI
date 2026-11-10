"""The operator invites a manager to the dashboard (#174, step 8.4.1): a one-time link for one
person in one organization, 15 minutes; recorded in the audit log without the code."""

import pytest

from missioncopilot_backend import admin, admin_dashboard
from tests.db.postgres import admin_url
from tests.db.test_admin_devices import _audit, ops  # noqa: F401 - the fixture

pytestmark = pytest.mark.db


def test_an_invite_link_works_once(ops):  # noqa: F811
    link, expires = admin_dashboard.invite_manager(
        admin_url(), ops.secrets, ops.org_id, "manager-1", "Amina Diallo", "https://mc.example.org"
    )

    assert link.startswith("https://mc.example.org/dashboard/invite/") and expires.endswith("UTC")
    code = link.rsplit("/", 1)[1]
    events = _audit(ops)
    assert ("manager_invited", ops.org_id, "operator:cli", None) in [
        e[:3] + (None,) for e in events
    ]
    assert code not in str(events)


def test_an_unknown_organization_or_a_plain_http_address_is_refused(ops):  # noqa: F811
    with pytest.raises(admin.AdminError, match="no organization"):
        admin_dashboard.invite_manager(
            admin_url(), ops.secrets, "t-nobody", "m", "M", "https://x.org"
        )
    with pytest.raises(admin.AdminError, match="https"):
        admin_dashboard.invite_manager(
            admin_url(), ops.secrets, ops.org_id, "m", "M", "http://x.org"
        )


def test_the_command_line_prints_the_link(ops, capsys):  # noqa: F811
    argv = ["invite-manager", ops.org_id, "manager-1", "--name", "Amina Diallo",
            "--base", "https://mc.example.org"]  # fmt: skip

    assert admin.main(argv, ops.env()) == 0

    out = capsys.readouterr().out
    assert "/dashboard/invite/" in out and "15 minutes" in out
