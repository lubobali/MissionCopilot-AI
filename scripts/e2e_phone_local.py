"""The phone and the real server, end to end, on this Mac (#90).

Usage: uv run --directory backend python ../scripts/e2e_phone_local.py
Needs the local Postgres with the demo loaded (backend/README.md) and the local signing key. It
starts the server on 127.0.0.1:8110, issues a one-time code for officer-7, and runs the app's
LocalServerE2ETests in the Simulator. Then it plays the operator: it approves the new phone when it
appears, and revokes it once that phone has downloaded the Kandor pack. Exit 0 only if the test
passed. Local development only: it changes the local directory (one phone, enrolled then revoked).
"""

import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import psycopg
from cryptography.hazmat.primitives import serialization

from missioncopilot_backend import admin, admin_devices
from missioncopilot_backend.admin_common import as_admin, directory_url
from missioncopilot_backend.settings import read_env_file
from missioncopilot_backend.signing_key import load_signing_key

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
ADDRESSES, KEY = BACKEND / ".db-addresses", BACKEND / ".keys" / "signing-key.pem"
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


def _downloads(admin_url: str) -> int:
    url = as_admin(admin_url, directory_url(ADDRESSES))
    with psycopg.connect(url) as conn:
        row = conn.execute("SELECT count(*) FROM audit_events WHERE kind = 'pack_downloaded'")
        return int(row.fetchone()[0])


def _operator(admin_url: str, test: subprocess.Popen, started: float) -> None:
    """Approve the new phone when it appears; revoke it after its pack download."""
    downloads, phone = _downloads(admin_url), None
    while test.poll() is None:
        phones = admin_devices.list_devices(admin_url, ADDRESSES, admin.DEMO_ORG)
        if phone is None:
            new = [p for p in phones if p.status == "pending" and p.enrolled_at >= started - 1]
            if new:
                phone = admin_devices.approve(
                    admin_url, ADDRESSES, new[-1].id, by="e2e-operator"
                ).id
                print(f"operator: approved {phone}")
        elif _downloads(admin_url) > downloads:
            admin_devices.revoke(admin_url, ADDRESSES, phone, by="e2e-operator")
            print(f"operator: revoked {phone} after its pack download")
            return
        time.sleep(1)


def main() -> int:
    admin_url = _admin_url()
    public = (
        load_signing_key(KEY)
        .public_key()
        .public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    )
    server = _server()
    try:
        started = time.time()
        code, _ = admin_devices.issue_code(admin_url, ADDRESSES, admin.DEMO_ORG, "officer-7", "e2e")
        env = os.environ | {
            "TEST_RUNNER_MC_E2E_BASE": BASE,
            "TEST_RUNNER_MC_E2E_CODE": code,
            "TEST_RUNNER_MC_E2E_KEYS": public.hex(),
            "TEST_RUNNER_MC_E2E_MISSION": admin.ROADS,
        }
        # To a file: a pipe nobody reads fills up and stalls xcodebuild (it did, the first run).
        log = (BACKEND / ".e2e-xcodebuild.log").open("w")  # noqa: SIM115 - closed after the run
        test = subprocess.Popen(
            ["xcodebuild", "test", "-project", "MissionCopilot.xcodeproj", "-scheme",  # noqa: S607
             "MissionCopilot", "-destination", "platform=iOS Simulator,name=iPhone 13 Pro Max",
             "-only-testing:MissionCopilotTests/LocalServerE2ETests"],
            cwd=ROOT / "ios", env=env, stdout=log, stderr=subprocess.STDOUT, text=True,
        )  # fmt: skip
        _operator(admin_url, test, started)
        test.wait(timeout=600)
        log.close()
        output = (BACKEND / ".e2e-xcodebuild.log").read_text(encoding="utf-8")
        print("\n".join(line for line in output.splitlines() if "Test run with" in line))
        return test.returncode
    finally:
        server.terminate()
        server.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
