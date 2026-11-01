"""Fail when the app's bill of materials stops matching what the app really runs (threats T50, T52).

docs/sbom/app.cdx.json lists the on-device model and the Swift packages. The model's hash must
be the weights digest inside the signed bundle, its version the full revision, and every Swift pin
in Package.resolved must appear at the same revision. The backend SBOM is built in CI from uv.lock.

Usage: python scripts/check_bom.py
"""

import base64
import json
import sys
from pathlib import Path

BOM = Path("docs/sbom/app.cdx.json")
SIGNATURE = Path("docs/models/LFM2.5-1.2B-Instruct-4bit.sig")
RESOLVED = Path("ios/AILab/EncryptionLab/Package.resolved")
WEIGHTS = "model.safetensors"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def signed_weights_digest(signature: dict) -> str:
    statement = json.loads(base64.b64decode(signature["dsseEnvelope"]["payload"]))
    return next(r["digest"] for r in statement["predicate"]["resources"] if r["name"] == WEIGHTS)


def model_problems(model: dict, signature: dict) -> list[str]:
    name = model["name"]
    hashes = {h["alg"]: h["content"] for h in model.get("hashes", [])}
    if hashes.get("SHA-256") != signed_weights_digest(signature):
        return [f"{name}: weights hash is not the one in the signed bundle"]
    if len(model.get("version", "")) != 40 or not model["purl"].endswith("@" + model["version"]):
        return [f"{name}: version must be the full 40-character revision"]
    return []


def pin_problems(components: list[dict], resolved: dict) -> list[str]:
    found = []
    for pin in resolved["pins"]:
        owner, repo = pin["location"].removesuffix(".git").split("/")[-2:]
        prefix = f"pkg:github/{owner}/{repo}@"
        purls = [c.get("purl", "") for c in components]
        listed = [purl.removeprefix(prefix) for purl in purls if purl.startswith(prefix)]
        revision = pin["state"]["revision"]
        if not listed:
            found.append(f"{pin['identity']}: pinned but not in the BOM")
        elif listed[0] != revision:
            found.append(f"{pin['identity']}: resolved at {revision}, BOM says {listed[0]}")
    return found


def problems(bom: dict, signature: dict, resolved: dict) -> list[str]:
    if bom.get("bomFormat") != "CycloneDX" or bom.get("specVersion") != "1.6":
        return ["not a CycloneDX 1.6 BOM"]
    components = bom.get("components", [])
    models = [c for c in components if c["type"] == "machine-learning-model"]
    if not models:
        return ["no machine-learning-model component"]
    found = [f"{c['name']}: no license recorded" for c in components if not c.get("licenses")]
    for model in models:
        found += model_problems(model, signature)
    return found + pin_problems(components, resolved)


def main() -> int:
    found = problems(load(BOM), load(SIGNATURE), load(RESOLVED))
    for problem in found:
        print(f"BOM: {problem}")
    if not found:
        print("OK: the BOM's model is the signed one and every Swift pin matches Package.resolved")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
