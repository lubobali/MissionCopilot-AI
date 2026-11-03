import base64
import json

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from make_shred_order_fixture import FIXTURE, ISSUED_AT

from missioncopilot_backend.shred_order import SHRED_PROBLEM, shred_message

pytestmark = pytest.mark.unit

DATA = json.loads(FIXTURE.read_text(encoding="utf-8"))


def test_the_fixture_is_a_genuine_shred_order_for_its_phone():
    body = json.loads(base64.b64decode(DATA["body"]))
    key = serialization.load_der_public_key(base64.b64decode(DATA["serverPublicKeyDER"]))
    assert isinstance(key, ec.EllipticCurvePublicKey)

    assert body["type"] == SHRED_PROBLEM and body["status"] == 410
    assert body["order"] == {"deviceId": DATA["deviceId"], "scope": "all-missions",
                             "issuedAt": ISSUED_AT}  # fmt: skip
    key.verify(
        base64.b64decode(body["signature"]),
        shred_message(DATA["deviceId"], ISSUED_AT),
        ec.ECDSA(hashes.SHA256()),
    )
