"""An app build the server no longer supports gets a clear "update the app" (#103 step 1.10, phone
side #104 step 104.7). The phone sends X-App-Build; below MISSIONCOPILOT_MIN_APP_BUILD a phone
request gets 403 with code app_too_old, before the signature check, so it never uses up a sequence
number. A missing header is too old (builds from before this change do not send it). Health is
never refused, so an old app can still read the server's time; the dashboard is never affected."""

from pathlib import Path

import pytest
import yaml
from fastapi import Depends
from jsonschema import Draft202012Validator

from missioncopilot_backend.app import create_app
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client
from tests.unit.test_device_requests import BODY, PATH, Clock, Phone

pytestmark = pytest.mark.unit

SPEC = yaml.safe_load(
    (Path(__file__).resolve().parents[3] / "docs/api/openapi.yaml").read_text(encoding="utf-8")
)
PHONE_OPERATIONS = {
    "getPackManifest",
    "getPackSignature",
    "getPackFile",
    "getOwnDevice",
    "listMyMissions",
    "uploadSyncBatch",
    "submitForReview",
    "enrollDevice",
}


def world(min_build: int):
    clock = Clock()
    devices = DeviceRegistry(clock=clock)
    app = create_app(Settings(min_app_build=min_build), devices=devices, clock=clock)
    router = device_router()

    @router.post("/test/missions/{mission_id}/sync")
    def sync(mission_id: str, device: DevicePrincipal = Depends(require_device)) -> dict:
        return {"device": device.device_id}

    app.include_router(router)
    return local_client(app), devices, clock


def send(client, headers):
    return client.post(PATH, content=BODY, headers=headers)


def test_off_by_default():
    assert Settings.from_env({}).min_app_build == 0
    client, devices, clock = world(0)

    assert send(client, Phone(devices).headers(PATH, BODY, clock.now)).status_code == 200


def test_the_minimum_comes_from_the_environment():
    assert Settings.from_env({"MISSIONCOPILOT_MIN_APP_BUILD": "42"}).min_app_build == 42


@pytest.mark.parametrize("value", ["-1", "4.2", "new"])
def test_the_minimum_must_be_a_whole_number(value):
    with pytest.raises(ValueError, match="MISSIONCOPILOT_MIN_APP_BUILD"):
        Settings.from_env({"MISSIONCOPILOT_MIN_APP_BUILD": value})


@pytest.mark.parametrize("build", [None, "41", "abc", "", "4 2", "-50"])
def test_an_old_missing_or_garbled_build_is_told_to_update(build):
    client, devices, clock = world(42)
    headers = Phone(devices).headers(PATH, BODY, clock.now)
    if build is not None:
        headers["X-App-Build"] = build

    answer = send(client, headers)

    assert answer.status_code == 403
    assert answer.headers["content-type"] == "application/problem+json"
    assert answer.headers["x-content-type-options"] == "nosniff"  # still inside the headers layer
    assert answer.json() == {
        "type": "about:blank",
        "title": "Forbidden",
        "status": 403,
        "detail": "This app build is too old; update the app.",
        "code": "app_too_old",
        "minAppBuild": 42,
    }


@pytest.mark.parametrize("build", ["42", "43", "1000"])
def test_the_minimum_build_and_newer_pass(build):
    client, devices, clock = world(42)
    headers = Phone(devices).headers(PATH, BODY, clock.now) | {"X-App-Build": build}

    assert send(client, headers).status_code == 200


def test_a_refused_request_keeps_its_sequence_number_usable():
    client, devices, clock = world(42)
    phone = Phone(devices)
    headers = phone.headers(PATH, BODY, clock.now)  # seq 1, no build header

    assert send(client, headers).status_code == 403
    assert send(client, headers | {"X-App-Build": "42"}).status_code == 200


def test_enrollment_from_an_old_app_is_told_to_update():
    client, _, _ = world(42)

    answer = client.post("/v1/devices/enroll", json={})

    assert (answer.status_code, answer.json()["code"]) == (403, "app_too_old")


def test_health_is_never_refused():
    client, _, _ = world(42)

    assert client.get("/v1/health", headers={"X-Device-Id": "x"}).status_code == 200


def test_the_dashboard_is_not_a_phone():
    client, _, _ = world(42)

    # No device id: a person's request goes on to its own check (here: no token, 401).
    assert client.get("/v1/devices").status_code == 401


def test_the_contract_documents_the_header_and_the_answer():
    operations = {op["operationId"]: op for item in SPEC["paths"].values() for op in item.values()}
    build = {"$ref": "#/components/parameters/AppBuild"}

    assert [o for o in PHONE_OPERATIONS if build not in operations[o].get("parameters", [])] == []
    assert [o for o in PHONE_OPERATIONS if "403" not in operations[o]["responses"]] == []
    assert SPEC["components"]["parameters"]["AppBuild"]["name"] == "X-App-Build"
    assert "parameters" not in operations["getHealth"]


def test_the_answer_matches_the_contract():
    client, devices, clock = world(42)
    answer = send(client, Phone(devices).headers(PATH, BODY, clock.now)).json()
    # The whole contract as the root, so its own references (Problem) resolve.
    pointer = "#/components/responses/AppTooOld/content/application~1problem+json/schema"
    validator = Draft202012Validator(SPEC | {"$ref": pointer})

    assert list(validator.iter_errors(answer)) == []
    assert not validator.is_valid(answer | {"code": "other"})
    assert not validator.is_valid({k: v for k, v in answer.items() if k != "minAppBuild"})


def test_a_negative_minimum_is_refused_in_code_too():
    with pytest.raises(ValueError, match="MISSIONCOPILOT_MIN_APP_BUILD"):
        Settings(min_app_build=-1)
