"""The production compose file (#103 step 2.2, B3, B4, B5, S13, S14), one file for staging and
prod, checked against the rules for a shared server: every container boxed in (memory, CPU,
processes, logs), the API on loopback only and read-only, Postgres with no port and no internet,
networks with explicit subnets (Docker's automatic pool must never pick one), secrets as files,
and the start order Postgres, then migrate, then the API."""

import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO = Path(__file__).resolve().parents[3]
COMPOSE = yaml.safe_load((REPO / "deploy" / "compose.yaml").read_text(encoding="utf-8"))
SERVICES = COMPOSE["services"]
CI = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
OURS = ("api", "migrate", "admin")  # run the backend image


def test_one_project_per_environment_and_every_name_ours():
    assert COMPOSE["name"] == "missioncopilot-${MC_ENV:?set MC_ENV to staging or prod}"
    assert set(SERVICES) == {"postgres", "migrate", "api", "admin"}
    assert [s for s in SERVICES.values() if "container_name" in s] == []  # project prefix only


@pytest.mark.parametrize("name", sorted(SERVICES))
def test_every_service_is_boxed_in(name):
    service = SERVICES[name]

    assert re.fullmatch(r"\d+m", str(service["mem_limit"]))
    assert service["memswap_limit"] == service["mem_limit"]  # no swap: the box's swap is full
    assert 0 < float(service["cpus"]) <= 1
    assert 0 < int(service["pids_limit"]) <= 512
    assert service["logging"]["options"] == {"max-size": "10m", "max-file": "3"}
    assert "no-new-privileges:true" in service["security_opt"]
    assert "ALL" in service["cap_drop"]
    assert not service.get("privileged")
    assert "network_mode" not in service
    mounts = " ".join(str(v) for v in service.get("volumes", []))
    assert "docker.sock" not in mounts


def test_only_the_api_publishes_a_port_and_only_on_loopback():
    published = {name: s["ports"] for name, s in SERVICES.items() if "ports" in s}

    assert published == {"api": ["127.0.0.1:${MC_PORT:?}:8110"]}


@pytest.mark.parametrize("name", OURS)
def test_our_containers_run_the_pinned_image_read_only_as_10001(name):
    service = SERVICES[name]

    assert service["image"] == "${MC_IMAGE:?set MC_IMAGE to the image by digest}"
    assert service["user"] == "10001:10001"
    assert service["read_only"] is True
    assert service["cap_drop"] == ["ALL"] and "cap_add" not in service


def test_postgres_is_cis_image_with_its_data_at_the_v18_path():
    postgres = SERVICES["postgres"]

    assert postgres["image"] in CI  # the same digest the tests run against
    assert re.search(r"@sha256:[0-9a-f]{64}$", postgres["image"])
    assert "pgdata:/var/lib/postgresql" in postgres["volumes"]  # 18+: not .../data
    assert postgres["networks"] == ["db"]
    secret = "/run/secrets/pg_admin_password"  # noqa: S105 - a file path, not a password
    assert postgres["environment"]["POSTGRES_PASSWORD_FILE"] == secret
    assert "timezone=UTC" in postgres["command"]


def test_networks_have_explicit_subnets_and_the_database_has_no_internet():
    networks = COMPOSE["networks"]

    assert networks["edge"]["ipam"]["config"] == [
        {"subnet": "${MC_EDGE_SUBNET:?}", "gateway": "${MC_EDGE_GATEWAY:?}"}
    ]
    assert networks["db"]["ipam"]["config"] == [{"subnet": "${MC_DB_SUBNET:?}"}]
    assert networks["db"]["internal"] is True
    assert SERVICES["api"]["networks"] == ["edge", "db"]
    assert SERVICES["migrate"]["networks"] == ["db"] and SERVICES["admin"]["networks"] == ["db"]


def test_the_api_believes_only_its_own_networks_gateway():
    env = SERVICES["api"]["environment"]

    assert env["MISSIONCOPILOT_FORWARDED_ALLOW_IPS"] == "${MC_EDGE_GATEWAY:?}"
    assert env["MISSIONCOPILOT_ALLOWED_HOSTS"] == "${MC_HOSTNAME:?},127.0.0.1"
    assert env["MISSIONCOPILOT_ENV"] == "production"
    assert env["MISSIONCOPILOT_HOST"] == "0.0.0.0"  # noqa: S104 - in the container; published on loopback


def test_no_secret_value_is_in_any_environment():
    for service in SERVICES.values():
        for key, value in service.get("environment", {}).items():
            if key.endswith("_FILE"):
                continue  # names a file: that is the rule
            if re.search(r"PASSWORD|_URL$|SECRET|KEY$", key):
                pytest.fail(f"{key} must come from a file (_FILE), not a value")
            assert "postgres://" not in str(value) and "postgresql://" not in str(value)


def test_secrets_are_files_from_the_environments_own_folder():
    assert COMPOSE["secrets"] == {
        "pg_admin_password": {"file": "${MC_SECRETS:?}/pg_admin_password"},
        "admin_url": {"file": "${MC_SECRETS:?}/admin_url"},
    }
    assert SERVICES["postgres"]["secrets"] == ["pg_admin_password"]
    assert "secrets" not in SERVICES["api"]  # the server never gets the admin login
    assert SERVICES["migrate"]["secrets"] == ["admin_url"] == SERVICES["admin"]["secrets"]


def test_the_api_reads_addresses_and_key_read_only_the_admin_writes_them():
    api, admin = SERVICES["api"], SERVICES["admin"]

    assert "${MC_SECRETS:?}/addresses:/run/mc/addresses:ro" in api["volumes"]
    assert "${MC_SECRETS:?}/keys:/run/mc/keys:ro" in api["volumes"]
    assert "${MC_SECRETS:?}/addresses:/run/mc/addresses" in admin["volumes"]
    assert "${MC_SECRETS:?}/keys:/run/mc/keys" in admin["volumes"]


def test_start_order_postgres_then_migrate_then_api():
    assert SERVICES["migrate"]["depends_on"] == {"postgres": {"condition": "service_healthy"}}
    assert SERVICES["api"]["depends_on"] == {
        "postgres": {"condition": "service_healthy"},
        "migrate": {"condition": "service_completed_successfully"},
    }
    assert "test" in SERVICES["postgres"]["healthcheck"]
    assert SERVICES["migrate"]["command"] == ["missioncopilot-admin", "migrate"]
    assert SERVICES["migrate"]["restart"] == "no"


def test_the_long_running_services_come_back_and_stop_gracefully():
    for name in ("postgres", "api"):
        assert SERVICES[name]["restart"] == "unless-stopped"
    assert SERVICES["api"]["init"] is True
    assert SERVICES["api"]["stop_grace_period"] == "30s"  # > the server's own 20 s
    assert SERVICES["postgres"]["stop_grace_period"] == "60s"  # a clean shutdown, no recovery
    assert SERVICES["api"]["tmpfs"] == ["/tmp:size=16m,mode=1777"]  # noqa: S108 - the rule itself


def test_admin_runs_only_on_purpose():
    assert SERVICES["admin"]["profiles"] == ["admin"]  # docker compose run --rm admin ...
