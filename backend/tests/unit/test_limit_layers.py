"""Two limits (#103 step 1.6, S3, API4:2023). Many officers can share one address (a hotel's Wi-Fi,
a carrier's NAT), so the per-address limit is loose: it only stops floods. The strict limit is per
phone, keyed by the device id, and counts only requests whose signature checked out: nobody else
can spend a phone's allowance. A refused request does not use up the phone's sequence number."""

import pytest
from fastapi import Depends, FastAPI

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client
from tests.unit.test_device_requests import BODY, PATH, Clock, Phone

pytestmark = pytest.mark.unit

MiB = 1_048_576


def test_defaults_loose_per_address_strict_per_phone():
    settings = Settings.from_env({})

    assert settings.rate_limit_per_minute == 600
    assert settings.device_rate_limit_per_minute == 120
    assert settings.max_body_bytes == MiB


def test_limits_come_from_the_environment():
    settings = Settings.from_env(
        {
            "MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE": "900",
            "MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE": "60",
            "MISSIONCOPILOT_MAX_BODY_BYTES": "2097152",
        }
    )

    assert (settings.rate_limit_per_minute, settings.device_rate_limit_per_minute) == (900, 60)
    assert settings.max_body_bytes == 2 * MiB


@pytest.mark.parametrize(
    "name",
    [
        "MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE",
        "MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE",
        "MISSIONCOPILOT_MAX_BODY_BYTES",
    ],
)
@pytest.mark.parametrize("value", ["0", "-5", "ten"])
def test_a_limit_must_be_a_positive_whole_number(name, value):
    with pytest.raises(ValueError, match=name):
        Settings.from_env({name: value})


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE", "59"),  # one officer's pack download is ~55
        ("MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE", "6001"),
        ("MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE", "29"),
        ("MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE", "1201"),
        ("MISSIONCOPILOT_MAX_BODY_BYTES", "65535"),
        ("MISSIONCOPILOT_MAX_BODY_BYTES", str(10 * MiB + 1)),
    ],
)
def test_production_refuses_limits_out_of_bounds(name, value):
    env = {"MISSIONCOPILOT_ALLOWED_HOSTS": "mc.lubot.ai", name: value}

    assert [p for p in Settings.from_env(env).unsafe() if name in p] != []


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE", "60"),
        ("MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE", "6000"),
        ("MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE", "30"),
        ("MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE", "1200"),
        ("MISSIONCOPILOT_MAX_BODY_BYTES", "65536"),
        ("MISSIONCOPILOT_MAX_BODY_BYTES", str(10 * MiB)),
    ],
)
def test_production_accepts_limits_at_the_bounds(name, value):
    env = {"MISSIONCOPILOT_ALLOWED_HOSTS": "mc.lubot.ai", name: value}

    assert Settings.from_env(env).unsafe() == []


@pytest.fixture
def world():
    clock, log = Clock(), AuditLog()
    devices = DeviceRegistry(clock=clock)
    settings = Settings(rate_limit_per_minute=1000, device_rate_limit_per_minute=2)
    app: FastAPI = create_app(settings, devices=devices, audit=log, clock=clock)
    router = device_router()

    @router.post("/test/missions/{mission_id}/sync")
    def sync(mission_id: str, device: DevicePrincipal = Depends(require_device)) -> dict:
        return {"device": device.device_id}

    app.include_router(router)
    return local_client(app), devices, clock, log


def send(client, headers):
    return client.post(PATH, content=BODY, headers=headers)


def test_a_phone_over_its_limit_gets_429_with_retry_after(world):
    client, devices, clock, _ = world
    phone = Phone(devices)

    answers = [send(client, phone.headers(PATH, BODY, clock.now)) for _ in range(3)]

    assert [a.status_code for a in answers] == [200, 200, 429]
    assert answers[2].headers["content-type"] == "application/problem+json"
    assert int(answers[2].headers["retry-after"]) > 0


def test_each_phone_has_its_own_limit_on_the_same_address(world):
    client, devices, clock, _ = world
    first, second = Phone(devices), Phone(devices)

    for _ in range(2):
        send(client, first.headers(PATH, BODY, clock.now))

    assert send(client, first.headers(PATH, BODY, clock.now)).status_code == 429
    assert send(client, second.headers(PATH, BODY, clock.now)).status_code == 200


def test_a_refused_request_keeps_its_sequence_number_usable(world):
    client, devices, clock, _ = world
    phone = Phone(devices)
    for _ in range(2):
        send(client, phone.headers(PATH, BODY, clock.now))
    limited = phone.headers(PATH, BODY, clock.now)  # seq 3

    assert send(client, limited).status_code == 429
    clock.now += 60
    assert send(client, phone.headers(PATH, BODY, clock.now, seq=3)).status_code == 200


def test_forged_requests_never_spend_a_phones_allowance(world):
    client, devices, clock, _ = world
    phone, stranger = Phone(devices), Phone(devices)

    for _ in range(5):  # signed with the wrong key, under the phone's id
        forged = phone.headers(PATH, BODY, clock.now, key=stranger.key)
        assert send(client, forged).status_code == 401

    assert send(client, phone.headers(PATH, BODY, clock.now)).status_code == 200


def test_a_limited_phone_is_recorded_once_per_spell(world):
    client, devices, clock, log = world
    phone = Phone(devices)

    for _ in range(5):
        send(client, phone.headers(PATH, BODY, clock.now))
    clock.now += 60
    send(client, phone.headers(PATH, BODY, clock.now))  # allowed again: the spell ends
    for _ in range(3):
        send(client, phone.headers(PATH, BODY, clock.now))

    limited = [e for e in log.events() if e.kind == "rate_limited"]
    assert [(e.subject, e.client) for e in limited] == [(phone.id, "testclient")] * 2
