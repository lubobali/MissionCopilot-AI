"""Write the exact bytes a phone signs, for the app's tests (#90).

Usage: uv run --directory backend python ../scripts/make_device_signing_fixture.py
Writes docs/api/fixtures/device-signing.json: fixed inputs and the bytes the server builds from them
(devices.enrollment_message, device_auth.request_message), base64. The app must build exactly the
same bytes. Nothing secret: the public key is a fixed example, never a real phone's.
"""

import base64
import json
import sys
from pathlib import Path

from missioncopilot_backend.device_auth import request_message
from missioncopilot_backend.devices import enrollment_message

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "docs" / "api" / "fixtures" / "device-signing.json"
KEY = bytes(range(91))  # stands in for a public key: only its bytes matter here
DEVICE = "6f1d2c3a-1111-4000-8000-000000000007"
MISSION = "6f1d2c3a-0000-4000-8000-000000000001"
SHA = "061fe12456fa15b79e78cf04d1cc36059d46673ab0fd1a805f16afb5b330beb0"
REQUESTS = [
    ("GET", f"/v1/missions/{MISSION}/pack/manifest", 1, 1_793_000_000, b""),
    ("GET", f"/v1/missions/{MISSION}/pack/files/{SHA}", 2, 1_793_000_001, b""),
    ("POST", f"/v1/missions/{MISSION}/sync", 3, 1_793_000_002, b'{"items":[]}'),
    ("GET", "/v1/devices?status=pending&limit=10", 41, 1_793_000_003, b""),
]


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def fixture() -> dict:
    code = "kq3X9vYb0M2tQ7wE1rLs"
    return {
        "enrollment": [
            {
                "code": code,
                "publicKeyDER": _b64(KEY),
                "message": _b64(enrollment_message(code, KEY)),
            }
        ],
        "requests": [
            {
                "method": method,
                "path": path,
                "deviceId": DEVICE,
                "seq": seq,
                "at": at,
                "body": _b64(body),
                "message": _b64(request_message(method, path, DEVICE, seq, at, body)),
            }
            for method, path, seq, at, body in REQUESTS
        ],
    }


def main() -> int:
    FIXTURE.write_text(json.dumps(fixture(), indent=2) + "\n", encoding="utf-8")
    print(f"OK: wrote {FIXTURE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
