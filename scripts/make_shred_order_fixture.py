"""Write a real shred order, as the server sends it to a revoked phone, for the app's tests (#60).

Usage: uv run --directory backend python ../scripts/make_shred_order_fixture.py
Writes docs/api/fixtures/shred-order.json: the 410 body exactly as the server answered a revoked
phone's signed request, the phone's device id, the time it was issued, and the public key that
signed it (DER, base64). The signing key is made for this run and thrown away.
"""

import base64
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.device_auth import request_message
from missioncopilot_backend.devices import DeviceRegistry, EnrollmentGrant
from missioncopilot_backend.settings import Settings

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "docs" / "api" / "fixtures" / "shred-order.json"
ISSUED_AT = 1_793_000_000


def shred_order() -> dict:
    """A revoked phone signs a request; the server answers with its signed order."""
    server_key = ec.generate_private_key(ec.SECP256R1())
    phone_key = ec.generate_private_key(ec.SECP256R1())
    devices = DeviceRegistry(clock=lambda: ISSUED_AT)
    der = phone_key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    device = devices.add(EnrollmentGrant("kandor-works", "officer-7", "phone", 0.0), der)
    if device is None:
        raise SystemExit("could not enroll the test phone")
    devices.update(device, status="revoked")
    path = "/v1/devices/me"
    message = request_message("GET", path, device.id, 1, ISSUED_AT, b"")
    headers = {
        "X-Device-Id": device.id,
        "X-Device-Seq": "1",
        "X-Device-Time": str(ISSUED_AT),
        "X-Device-Signature": base64.b64encode(
            phone_key.sign(message, ec.ECDSA(hashes.SHA256()))
        ).decode(),
    }
    app = create_app(Settings(), devices=devices, signing_key=server_key)
    answer = TestClient(app, base_url="http://localhost").get(path, headers=headers)
    if answer.status_code != 410:
        raise SystemExit(f"expected a shred order, got {answer.status_code}: {answer.text}")
    public = server_key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return {
        "deviceId": device.id,
        "issuedAt": ISSUED_AT,
        "serverPublicKeyDER": base64.b64encode(public).decode(),
        "body": base64.b64encode(answer.content).decode(),
    }


def main() -> int:
    FIXTURE.write_text(json.dumps(shred_order(), indent=2) + "\n", encoding="utf-8")
    print(f"OK: wrote {FIXTURE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
