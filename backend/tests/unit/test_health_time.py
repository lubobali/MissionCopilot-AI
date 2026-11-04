"""Health tells the phone the server's time (#103 step 1.7). A signed request must be within 300 s
of the server's clock, so a phone with a wrong clock measures its offset here and corrects for it.
The time is the very clock the signature window uses, and the answer is checked against the
contract's own schema, so the code and docs/api/openapi.yaml cannot drift apart."""

from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator

from missioncopilot_backend.app import create_app
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

SPEC = Path(__file__).resolve().parents[3] / "docs" / "api" / "openapi.yaml"


def health(now: float) -> dict:
    devices = DeviceRegistry(clock=lambda: now)
    return local_client(create_app(Settings(), devices=devices)).get("/v1/health").json()


def test_health_sends_the_time_the_signature_window_uses():
    assert health(1_800_000_123.9) == {"status": "ok", "time": 1_800_000_123}


def test_the_answer_matches_the_contract():
    spec = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    schema = spec["paths"]["/v1/health"]["get"]["responses"]["200"]["content"]["application/json"]

    validator = Draft202012Validator(schema["schema"])

    assert list(validator.iter_errors(health(1_800_000_000.0))) == []
    assert not validator.is_valid({"status": "ok"})  # the contract requires the time
    assert not validator.is_valid({"status": "ok", "time": 1_800_000_000.5})  # whole seconds
    assert not validator.is_valid({"status": "ok", "time": "1800000000"})  # whole seconds, a number
