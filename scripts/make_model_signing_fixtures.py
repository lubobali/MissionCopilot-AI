"""Build the model-signing fixtures for the iPhone verifier's tests (threat model T46).

A tiny fake model is signed with the official OpenSSF Model Signing tool and a throwaway test key,
so the Swift verifier is tested against real bundles, not ones we made up. The official verifier's
verdicts are recorded in expected.json, and the Swift tests must agree with every one. A few bundles
the official tool would never make are signed by hand with the same test key (a wrong payload type,
a file name that climbs out of the model folder), to test the checks behind the signature.

The test key is thrown away: it signs nothing but these fixtures.
Run: uv run --directory backend python ../scripts/make_model_signing_fixtures.py
"""

import base64
import hashlib
import json
import shutil
import subprocess  # noqa: S404 - the pinned official tool
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from sign_model import sign_command, verify_command

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "ios" / "MissionCopilotTests" / "Fixtures" / "ModelSigning"
DSSE_TYPE = "application/vnd.in-toto+json"


def pae(payload_type: str, payload: bytes) -> bytes:
    """DSSE pre-authentication encoding: the exact bytes a DSSE signature covers."""
    kind = payload_type.encode()
    return b"DSSEv1 %d %s %d %s" % (len(kind), kind, len(payload), payload)


def fake_model(folder: Path) -> None:
    folder.mkdir(parents=True)
    (folder / "config.json").write_text('{"model_type": "fixture"}\n')
    (folder / "tokenizer.json").write_text('{"vocab": ["a", "b"]}\n')
    weights = b"".join(hashlib.sha256(bytes([n])).digest() for n in range(256))  # 8 KiB, fixed
    (folder / "model.safetensors").write_bytes(weights)


def official(command: list[str]) -> bool:  # pragma: no cover - runs the real tool
    return subprocess.run(command, capture_output=True, check=False).returncode == 0  # noqa: S603


def hand_signed(
    bundle: dict, key: ec.EllipticCurvePrivateKey, payload_type: str, statement: dict
) -> dict:
    payload = json.dumps(statement).encode()
    signature = key.sign(pae(payload_type, payload), ec.ECDSA(hashes.SHA256()))
    envelope = {
        "payload": base64.b64encode(payload).decode(),
        "payloadType": payload_type,
        "signatures": [{"sig": base64.b64encode(signature).decode(), "keyid": ""}],
    }
    return bundle | {"dsseEnvelope": envelope}


def main() -> None:  # pragma: no cover - builds files with the real tool
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        key = ec.generate_private_key(ec.SECP256R1())
        (tmp / "key.pem").write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        public = key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        )
        other = (
            ec.generate_private_key(ec.SECP256R1())
            .public_key()
            .public_bytes(
                serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
            )
        )
        shutil.rmtree(OUT, ignore_errors=True)
        model = OUT / "fixture-model"
        fake_model(model)
        (OUT / "test-key.pub").write_bytes(public)
        (OUT / "other-key.pub").write_bytes(other)
        good = OUT / "good.sig"
        if not official(sign_command(str(model), str(tmp / "key.pem"), str(good))):
            raise SystemExit("the official tool could not sign the fixture model")
        good.write_text(good.read_text().rstrip("\n") + "\n")  # one final newline, like every file

        expected = {
            "good": official(verify_command(str(model), str(OUT / "test-key.pub"), str(good)))
        }
        expected["other key"] = official(
            verify_command(str(model), str(OUT / "other-key.pub"), str(good))
        )
        for name, change in {
            "one byte changed": lambda m: (m / "model.safetensors").write_bytes(
                b"X" + (m / "model.safetensors").read_bytes()[1:]
            ),
            "extra file": lambda m: (m / "extra.py").write_text("print('hi')\n"),
            "missing file": lambda m: (m / "tokenizer.json").unlink(),
        }.items():
            copy = tmp / name.replace(" ", "-")
            shutil.copytree(model, copy)
            change(copy)
            expected[name] = official(
                verify_command(str(copy), str(OUT / "test-key.pub"), str(good))
            )

        bundle = json.loads(good.read_text())
        statement = json.loads(base64.b64decode(bundle["dsseEnvelope"]["payload"]))
        forged = json.loads(json.dumps(statement))
        forged["predicate"]["resources"][0]["digest"] = "0" * 64
        envelope = bundle["dsseEnvelope"] | {
            "payload": base64.b64encode(json.dumps(forged).encode()).decode()
        }
        (OUT / "forged-digest.sig").write_text(
            json.dumps(bundle | {"dsseEnvelope": envelope}) + "\n"
        )
        (OUT / "wrong-type.sig").write_text(
            json.dumps(hand_signed(bundle, key, "text/plain", statement)) + "\n"
        )
        climbing = json.loads(json.dumps(statement))
        climbing["predicate"]["resources"][0]["name"] = "../outside.json"
        (OUT / "climbing-name.sig").write_text(
            json.dumps(hand_signed(bundle, key, DSSE_TYPE, climbing)) + "\n"
        )
        inconsistent = json.loads(json.dumps(statement))
        inconsistent["subject"][0]["digest"]["sha256"] = "0" * 64
        (OUT / "wrong-subject.sig").write_text(
            json.dumps(hand_signed(bundle, key, DSSE_TYPE, inconsistent)) + "\n"
        )
        (OUT / "expected.json").write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")
        print(f"Wrote {OUT}: official verdicts {expected}")


if __name__ == "__main__":
    main()
