"""Local Postgres (backend/compose.yaml) and CI run the same pinned image, reachable only from the
same machine, with no password written in the repo (#88)."""

import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
COMPOSE = yaml.safe_load((ROOT / "backend" / "compose.yaml").read_text(encoding="utf-8"))
POSTGRES = COMPOSE["services"]["postgres"]
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
PINNED = re.compile(r"^postgres:18\.\d+-trixie@sha256:[0-9a-f]{64}$")


def test_local_postgres_is_18_pinned_by_digest():
    assert PINNED.match(POSTGRES["image"])


def test_ci_runs_the_same_image():
    assert POSTGRES["image"] in CI


def test_local_postgres_listens_on_this_machine_only():
    assert POSTGRES["ports"] == ["127.0.0.1:55432:5432"]


def test_no_password_is_written_in_the_repo():
    password = POSTGRES["environment"]["POSTGRES_PASSWORD"]

    assert password.startswith("${") and ":?" in password  # from backend/.env, or compose refuses
