"""Where the server listens and which proxy it believes (#103 step 1.2, B1, B7). Behind nginx every
phone arrives from the proxy's address, so the real address comes from X-Forwarded-For, and only
when the proxy itself sent it: anyone else can write that header. By default no proxy is trusted
(uvicorn alone would trust loopback, and on a shared server other programs can reach loopback)."""

import asyncio

import pytest
import uvicorn

import missioncopilot_backend
from missioncopilot_backend import uvicorn_options
from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.settings import Settings

pytestmark = pytest.mark.unit

PROXY = "192.168.250.1"  # the gateway of the app's own Docker network, where host nginx comes from
PHONE = "203.0.113.9"  # documentation addresses (RFC 5737)
OTHER_PHONE = "198.51.100.7"


def test_by_default_only_this_machine_and_no_proxy():
    settings = Settings.from_env({})

    assert (settings.host, settings.port, settings.forwarded_allow_ips) == ("127.0.0.1", 8110, ())


def test_listen_address_and_proxy_come_from_the_environment():
    settings = Settings.from_env(
        {
            "MISSIONCOPILOT_HOST": "0.0.0.0",  # noqa: S104 - inside a container, published on loopback
            "MISSIONCOPILOT_PORT": "8122",
            "MISSIONCOPILOT_FORWARDED_ALLOW_IPS": f"{PROXY}, 192.168.251.0/24",
        }
    )

    assert settings.host == "0.0.0.0"  # noqa: S104
    assert settings.port == 8122
    assert settings.forwarded_allow_ips == (PROXY, "192.168.251.0/24")


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("MISSIONCOPILOT_HOST", "mc.lubot.ai"),  # a name could resolve anywhere; an address only
        ("MISSIONCOPILOT_HOST", ""),
        ("MISSIONCOPILOT_PORT", "80a"),
        ("MISSIONCOPILOT_PORT", "0"),
        ("MISSIONCOPILOT_PORT", "65536"),
        ("MISSIONCOPILOT_FORWARDED_ALLOW_IPS", "*"),  # would believe anyone's header
        ("MISSIONCOPILOT_FORWARDED_ALLOW_IPS", "nginx"),  # uvicorn would quietly keep it as text
        ("MISSIONCOPILOT_FORWARDED_ALLOW_IPS", "192.168.250.1/24"),  # a host, not a network
    ],
)
def test_a_wrong_value_stops_the_start_and_names_the_setting(name, value):
    with pytest.raises(ValueError, match=name):
        Settings.from_env({name: value})


def test_without_a_proxy_the_forwarded_headers_are_off():
    options = uvicorn_options(Settings())

    assert options["proxy_headers"] is False
    assert options["forwarded_allow_ips"] == []


def test_with_a_proxy_only_that_proxy_is_believed():
    options = uvicorn_options(Settings(forwarded_allow_ips=(PROXY,)))

    assert options["proxy_headers"] is True
    assert options["forwarded_allow_ips"] == [PROXY]


def test_the_server_names_no_software_and_stops_gracefully():
    options = uvicorn_options(Settings(host="0.0.0.0", port=8122))  # noqa: S104

    assert (options["host"], options["port"]) == ("0.0.0.0", 8122)  # noqa: S104
    assert options["server_header"] is False
    assert options["timeout_graceful_shutdown"] == 20  # below the container's stop grace period


def test_main_runs_the_checked_server_factory_with_these_options(monkeypatch):
    calls = []
    monkeypatch.setattr(uvicorn, "run", lambda app, **kwargs: calls.append((app, kwargs)))

    missioncopilot_backend.main({"MISSIONCOPILOT_PORT": "8122"})

    [(app, kwargs)] = calls
    assert app == "missioncopilot_backend.server:build"
    assert kwargs["factory"] is True
    assert kwargs["port"] == 8122
    assert kwargs["proxy_headers"] is False


def served(settings: Settings, audit: AuditLog):
    """The app exactly as uvicorn serves it, its own proxy-header middleware included."""
    app = create_app(settings, audit=audit)
    config = uvicorn.Config(app, **uvicorn_options(settings), log_config=None)
    config.load()
    return config.loaded_app


def statuses(app, peer: str, forwarded_for: list[str]) -> list[int]:
    async def one(header: str) -> int:
        headers = [(b"host", b"localhost"), (b"x-forwarded-for", header.encode())]
        scope = {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "GET",
            "scheme": "http",
            "path": "/v1/health",
            "raw_path": b"/v1/health",
            "query_string": b"",
            "root_path": "",
            "headers": headers,
            "client": (peer, 40000),
            "server": ("127.0.0.1", 8110),
        }
        sent = []

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            sent.append(message)

        await app(scope, receive, send)
        return sent[0]["status"]

    return [asyncio.run(one(header)) for header in forwarded_for]


def limited_clients(audit: AuditLog) -> list[str | None]:
    return [event.client for event in audit.events() if event.kind == "rate_limited"]


def test_a_forwarded_address_from_an_untrusted_peer_changes_nothing():
    audit = AuditLog()
    app = served(Settings(rate_limit_per_minute=1, forwarded_allow_ips=(PROXY,)), audit)

    # Not the proxy: a new X-Forwarded-For each time must not buy a new rate-limit bucket.
    assert statuses(app, "192.0.2.50", [PHONE, OTHER_PHONE]) == [200, 429]
    assert limited_clients(audit) == ["192.0.2.50"]


def test_loopback_is_not_trusted_unless_named():
    audit = AuditLog()
    app = served(Settings(rate_limit_per_minute=1), audit)

    assert statuses(app, "127.0.0.1", [PHONE, OTHER_PHONE]) == [200, 429]
    assert limited_clients(audit) == ["127.0.0.1"]


def test_behind_the_trusted_proxy_each_phone_has_its_own_address():
    audit = AuditLog()
    app = served(Settings(rate_limit_per_minute=1, forwarded_allow_ips=(PROXY,)), audit)

    assert statuses(app, PROXY, [PHONE, OTHER_PHONE, PHONE]) == [200, 200, 429]
    assert limited_clients(audit) == [PHONE]  # the audit log names the phone, not the proxy


def test_a_phone_cannot_choose_its_address_by_adding_to_the_header():
    audit = AuditLog()
    app = served(Settings(rate_limit_per_minute=1, forwarded_allow_ips=(PROXY,)), audit)

    # Only the last address, the one the proxy added, counts; earlier ones are the phone's words.
    forged = [f"1.1.1.1, {PHONE}", f"2.2.2.2, {PHONE}"]
    assert statuses(app, PROXY, forged) == [200, 429]
    assert limited_clients(audit) == [PHONE]
