"""Sign and verify the on-device model with the official OpenSSF Model Signing tool (threat T46).

The bundle is a sigstore bundle: a DSSE envelope over an in-toto statement listing every model
file's SHA-256, signed with our own P-256 key. The iPhone checks the same bundle with CryptoKit.
The private key lives in private/ and is never committed; the public key and the bundle are.

model-signing 1.1.1 does not declare its pyOpenSSL dependency (it crashes without it), so both are
pinned. --ignore-paths is resolved from the working directory, not the model folder: the download
cache is passed as <model>/.cache, or it would be signed too.

Usage:
  python scripts/sign_model.py sign   <model dir> <private key PEM> <bundle>
  python scripts/sign_model.py verify <model dir> <public key PEM>  <bundle>
"""

import subprocess  # noqa: S404 - fixed, pinned tool; paths from the command line
import sys

MODEL_SIGNING = "model-signing==1.1.1"
PYOPENSSL = "pyopenssl==26.4.0"


def _tool() -> list[str]:
    return ["uvx", "--from", MODEL_SIGNING, "--with", PYOPENSSL, "model_signing"]


def sign_command(model_dir: str, private_key: str, bundle: str) -> list[str]:
    return [
        *_tool(), "sign", "key", model_dir,
        "--private_key", private_key,
        "--signature", bundle,
        "--ignore-paths", f"{model_dir}/.cache",
    ]  # fmt: skip


def verify_command(model_dir: str, public_key: str, bundle: str) -> list[str]:
    return [
        *_tool(), "verify", "key", model_dir,
        "--public_key", public_key,
        "--signature", bundle,
        "--ignore-paths", f"{model_dir}/.cache",
    ]  # fmt: skip


def main(argv: list[str]) -> int:  # pragma: no cover - runs the real tool
    action, model_dir, key, bundle = argv
    command = (sign_command if action == "sign" else verify_command)(model_dir, key, bundle)
    return subprocess.run(command, check=False).returncode  # noqa: S603 - pinned tool


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
