"""The phone and the real server, end to end, on this Mac (#90).

Usage: uv run --directory backend python ../scripts/e2e_phone_local.py
Needs the local Postgres with the demo loaded (backend/README.md) and the local signing key. It
starts the server on 127.0.0.1:8110, issues a one-time code for officer-7, and runs the app's
LocalServerE2ETests in the Simulator. Then it plays the operator: it approves the new phone when
it appears, publishes the next version of the Kandor roads pack once the phone holds the first
(#91), and revokes the phone once it has checked the packs. The two keep in step with marker files
in a temporary folder. Exit 0 only if the test passed. Local development only: it changes the local
databases (one phone, enrolled then revoked; one more pack version, as packs are append-only).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import serialization

from missioncopilot_backend import admin, admin_devices
from missioncopilot_backend.settings import read_env_file
from missioncopilot_backend.signing_key import load_signing_key

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
ADDRESSES, KEY = BACKEND / ".db-addresses", BACKEND / ".keys" / "signing-key.pem"
WAIT_SECONDS = 600
BASE = "http://127.0.0.1:8110"


def _admin_url() -> str:
    url = os.environ.get("MISSIONCOPILOT_ADMIN_URL") or read_env_file(BACKEND / ".env").get(
        "MISSIONCOPILOT_ADMIN_URL"
    )
    if not url:
        raise SystemExit("no admin address: run scripts/make_dev_env.py")
    return url


def _server() -> subprocess.Popen:
    env = os.environ | {
        "MISSIONCOPILOT_ENV": "development",
        "MISSIONCOPILOT_DIRECTORY_URL_FILE": str(ADDRESSES / "directory.url"),
        "MISSIONCOPILOT_ORG_URLS_DIR": str(ADDRESSES / "orgs"),
        "MISSIONCOPILOT_SIGNING_KEY_FILE": str(KEY),
    }
    server = subprocess.Popen(
        ["uv", "run", "missioncopilot-backend"], cwd=BACKEND, env=env,  # noqa: S607 - dev tool
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )  # fmt: skip
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"{BASE}/v1/health", timeout=1) as answer:  # noqa: S310 - local
                if answer.status == 200:
                    return server
        except OSError:
            time.sleep(0.5)
    server.terminate()
    raise SystemExit("the local server did not start")


def _operator(admin_url: str, test: subprocess.Popen, started: float, signals: Path) -> None:
    """Approve the new phone when it appears, publish the next pack when it holds the first, and
    revoke it once it has checked the packs."""
    phone, published = None, False
    while test.poll() is None:
        if phone is None:
            phones = admin_devices.list_devices(admin_url, ADDRESSES, admin.DEMO_ORG)
            new = [p for p in phones if p.status == "pending" and p.enrolled_at >= started - 1]
            if new:
                phone = admin_devices.approve(
                    admin_url, ADDRESSES, new[-1].id, by="e2e-operator"
                ).id
                print(f"operator: approved {phone}")
        elif not published and (signals / "first-pack").exists():
            pack = admin.publish_demo_pack(admin_url, KEY)
            published = True
            print(f"operator: published pack version {pack.version}")
        elif (signals / "packs-checked").exists():
            admin_devices.revoke(admin_url, ADDRESSES, phone, by="e2e-operator")
            print(f"operator: revoked {phone} after its pack checks")
            return
        time.sleep(1)


def main() -> int:
    admin_url = _admin_url()
    public = (
        load_signing_key(KEY)
        .public_key()
        .public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    )
    signals = Path(tempfile.mkdtemp(prefix="mc-e2e-"))
    server = _server()
    try:
        started = time.time()
        code, _ = admin_devices.issue_code(admin_url, ADDRESSES, admin.DEMO_ORG, "officer-7", "e2e")
        env = os.environ | {
            "TEST_RUNNER_MC_E2E_BASE": BASE,
            "TEST_RUNNER_MC_E2E_CODE": code,
            "TEST_RUNNER_MC_E2E_KEYS": public.hex(),
            "TEST_RUNNER_MC_E2E_MISSION": admin.ROADS,
            "TEST_RUNNER_MC_E2E_SIGNALS": str(signals),
        }
        # To a file: a pipe nobody reads fills up and stalls xcodebuild (it did, the first run).
        log = (BACKEND / ".e2e-xcodebuild.log").open("w")  # noqa: SIM115 - closed after the run
        test = subprocess.Popen(
            ["xcodebuild", "test", "-project", "MissionCopilot.xcodeproj", "-scheme",  # noqa: S607
             "MissionCopilot", "-destination", "platform=iOS Simulator,name=iPhone 13 Pro Max",
             "-only-testing:MissionCopilotTests/LocalServerE2ETests"],
            cwd=ROOT / "ios", env=env, stdout=log, stderr=subprocess.STDOUT, text=True,
        )  # fmt: skip
        _operator(admin_url, test, started, signals)
        test.wait(timeout=WAIT_SECONDS)
        log.close()
        output = (BACKEND / ".e2e-xcodebuild.log").read_text(encoding="utf-8")
        print("\n".join(line for line in output.splitlines() if "Test run with" in line))
        return test.returncode
    finally:
        shutil.rmtree(signals, ignore_errors=True)
        server.terminate()
        server.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
