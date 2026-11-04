import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

UNITS = Path(__file__).resolve().parents[1] / "deploy" / "systemd"
SCRIPT = "/srv/missioncopilot-dev/scripts/mc_backup.py"
WHERE = (
    "--values /srv/missioncopilot/%i/values.env --restic-env /srv/missioncopilot/%i/backup.env"
    " --password-file /srv/missioncopilot/backup/restic-password"
)


def _unit(name: str) -> str:
    return (UNITS / name).read_text(encoding="utf-8")


def _starts(service: str) -> list[str]:
    """The active ExecStart lines, in order (a commented-out one does not run)."""
    return [line for line in service.splitlines() if line.startswith("ExecStart=")]


def _hour(timer: str) -> int:
    found = re.search(r"^OnCalendar=.* (\d\d):\d\d:\d\d UTC$", timer, flags=re.MULTILINE)
    assert found, timer
    return int(found.group(1))


def test_the_nightly_backup_runs_once_outside_the_servers_busy_hours():
    service, timer = _unit("missioncopilot-backup@.service"), _unit("missioncopilot-backup@.timer")

    assert "Type=oneshot" in service
    assert _starts(service) == [f"ExecStart=/usr/bin/python3 {SCRIPT} backup {WHERE}"]
    assert "OnCalendar=*-*-* 07:15:00 UTC" in timer
    assert not 0 <= _hour(timer) < 7  # 00:00-06:30 UTC: the other apps' backups and cleanups
    assert "Persistent=true" in timer  # a run missed while the server was down happens later


def test_every_week_a_backup_is_restored_and_its_data_read_back():
    service, timer = (
        _unit("missioncopilot-backup-check@.service"),
        _unit("missioncopilot-backup-check@.timer"),
    )

    assert _starts(service) == [
        f"ExecStart=/usr/bin/python3 {SCRIPT} restore-check {WHERE}",
        f"ExecStart=/usr/bin/python3 {SCRIPT} verify {WHERE}",
    ]
    assert "OnCalendar=Sun *-*-* 08:00:00 UTC" in timer
    assert not 0 <= _hour(timer) < 7


@pytest.mark.parametrize(
    "name", ["missioncopilot-backup@.service", "missioncopilot-backup-check@.service"]
)
def test_backups_are_gentle_with_the_shared_server(name):
    service = _unit(name)

    assert "Nice=10" in service and "IOSchedulingClass=idle" in service
    assert "Requires=docker.service" in service and "After=docker.service" in service
