"""Write the signed Kandor mission pack the app's tests use (#89, used by #91 and #92).

Usage: uv run --directory backend python ../scripts/make_pack_fixture.py
Writes docs/api/fixtures/pack-v2-kandor/: manifest.json and signature.json exactly as the server
serves them, public-key.der.b64 (the key to pin in the tests) and files/<sha256> for each file.
The signing key is made for this run and thrown away: only its public half is written. Rerun after
changing the demo dataset; a backend test fails while the fixture is out of date.
"""

import base64
import json
import shutil
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.pack_content import pack_files
from missioncopilot_backend.pack_format import build_manifest, key_id, sign_manifest

ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / "docs" / "demo" / "kandor-rural-roads.json"
FIXTURE = ROOT / "docs" / "api" / "fixtures" / "pack-v2-kandor"
CREATED = datetime(2026, 11, 3, 12, 0, tzinfo=UTC)
VALID_FOR = timedelta(days=3650)  # a fixture must not expire under the tests
PACK_ID = "0b6f0a52-6a0b-4c55-9d0e-3f1a2b3c4d5e"


def write_fixture(folder: Path = FIXTURE, dataset: Path = DATASET) -> None:
    data = json.loads(dataset.read_text(encoding="utf-8"))
    files = pack_files(data)
    key = ec.generate_private_key(ec.SECP256R1())
    manifest = build_manifest(
        org_id="kandor-works",
        mission_id=data["mission"]["id"],
        version=1,
        files=files,
        created_at=CREATED,
        valid_for=VALID_FOR,
        min_app_version="0.5",
        key_id=key_id(key.public_key()),
        pack_id=PACK_ID,
    )
    if folder.exists():
        shutil.rmtree(folder)
    (folder / "files").mkdir(parents=True)
    (folder / "manifest.json").write_bytes(manifest)
    signature = sign_manifest(manifest, key)
    (folder / "signature.json").write_text(json.dumps(signature, indent=2) + "\n", encoding="utf-8")
    der = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    (folder / "public-key.der.b64").write_text(base64.b64encode(der).decode() + "\n")
    for entry in json.loads(manifest)["files"]:
        (folder / "files" / entry["sha256"]).write_bytes(files[entry["path"]])


def main() -> int:
    write_fixture()
    print(f"OK: wrote {FIXTURE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
