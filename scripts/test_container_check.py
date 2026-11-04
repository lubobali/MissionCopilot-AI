import argparse
from pathlib import Path

import pytest
import yaml
from container_check import COMPOSE, POSTGRES_UID, SERVER_UID, secrets_layout, values

pytestmark = pytest.mark.unit

ARGS = argparse.Namespace(
    port=8122,
    edge_subnet="192.168.252.64/26",
    edge_gateway="192.168.252.65",
    db_subnet="192.168.252.128/26",
)


def test_the_values_cover_every_required_variable_of_the_compose_file():
    text = COMPOSE.read_text(encoding="utf-8")
    required = {part.split(":?")[0] for part in text.split("${")[1:] if ":?" in part.split("}")[0]}

    assert required <= set(values(ARGS, "img@sha256:x", Path("/s")))


def test_the_check_runs_as_its_own_project_on_its_own_subnets():
    found = values(ARGS, "img", Path("/s"))

    assert found["MC_ENV"] == "check"  # project missioncopilot-check, never staging or prod
    assert (found["MC_EDGE_SUBNET"], found["MC_DB_SUBNET"]) == (ARGS.edge_subnet, ARGS.db_subnet)


def test_each_secret_is_owned_by_the_user_its_container_runs_as():
    compose = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
    layout = secrets_layout()

    assert layout["pg_admin_password"] == (POSTGRES_UID, 0o600)  # read by the postgres image
    assert compose["services"]["api"]["user"] == f"{SERVER_UID}:{SERVER_UID}"
    assert {layout[n] for n in ("admin_url", "addresses", "keys")} == {
        (SERVER_UID, 0o600),
        (SERVER_UID, 0o700),
    }
    assert all(mode & 0o077 == 0 for name, (_, mode) in layout.items() if name != ".")
