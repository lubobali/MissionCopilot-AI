"""Requests signed by the app, checked by the server (#90). The app's tests signed each fixture
request with a key in the chip's format and wrote them (docs/api/fixtures/device-signing-app.json);
the server must accept those signatures over exactly the bytes it builds itself, nothing else."""

import base64
import json
from pathlib import Path

import pytest

from missioncopilot_backend.device_auth import request_message
from missioncopilot_backend.signatures import is_signed_by, load_p256_public_key

pytestmark = pytest.mark.unit

FIXTURES = Path(__file__).resolve().parents[3] / "docs" / "api" / "fixtures"
INPUTS = json.loads((FIXTURES / "device-signing.json").read_text(encoding="utf-8"))["requests"]
APP = json.loads((FIXTURES / "device-signing-app.json").read_text(encoding="utf-8"))
KEY = load_p256_public_key(base64.b64decode(APP["publicKeyDER"]))


def _server_bytes(request: dict) -> bytes:
    body = base64.b64decode(request["body"])
    return request_message(
        request["method"], request["path"], request["deviceId"], request["seq"], request["at"], body
    )


def test_the_app_signed_every_fixture_request():
    assert KEY is not None
    assert len(APP["signed"]) == len(INPUTS)


@pytest.mark.parametrize("index", range(len(INPUTS)))
def test_the_server_accepts_the_apps_signature_over_its_own_bytes(index):
    signed = APP["signed"][index]
    assert KEY is not None

    assert base64.b64decode(signed["message"]) == _server_bytes(INPUTS[index])
    assert is_signed_by(KEY, base64.b64decode(signed["signature"]), _server_bytes(INPUTS[index]))


@pytest.mark.parametrize("index", range(len(INPUTS)))
def test_a_signature_does_not_fit_any_other_request(index):
    signature = base64.b64decode(APP["signed"][index]["signature"])
    assert KEY is not None

    others = [_server_bytes(r) for i, r in enumerate(INPUTS) if i != index]
    assert not any(is_signed_by(KEY, signature, other) for other in others)


def test_one_changed_byte_in_the_signed_request_is_refused():
    signed = APP["signed"][0]
    message = bytearray(_server_bytes(INPUTS[0]))
    message[-1] ^= 0x01
    assert KEY is not None

    assert not is_signed_by(KEY, base64.b64decode(signed["signature"]), bytes(message))
