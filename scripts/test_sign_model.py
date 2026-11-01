"""The model is signed and checked with the official OpenSSF Model Signing tool, always the same
pinned way, so a signature made today verifies the same tomorrow (threat model T46)."""

import pytest
from sign_model import MODEL_SIGNING, PYOPENSSL, sign_command, verify_command

pytestmark = pytest.mark.unit


def test_the_official_tool_is_pinned_with_its_missing_dependency():
    command = sign_command("models/m", "private/keys/k.pem", "docs/models/m.sig")

    assert command[:5] == ["uvx", "--from", MODEL_SIGNING, "--with", PYOPENSSL]
    assert MODEL_SIGNING == "model-signing==1.1.1"
    assert PYOPENSSL == "pyopenssl==26.4.0"


def test_signing_uses_our_own_key_and_leaves_out_download_leftovers():
    command = sign_command("models/m", "private/keys/k.pem", "docs/models/m.sig")

    assert command[5:] == [
        "model_signing", "sign", "key", "models/m",
        "--private_key", "private/keys/k.pem",
        "--signature", "docs/models/m.sig",
        "--ignore-paths", "models/m/.cache",
    ]  # fmt: skip


def test_verifying_needs_only_the_public_key():
    command = verify_command("models/m", "docs/models/key.pub.pem", "docs/models/m.sig")

    assert command[5:] == [
        "model_signing", "verify", "key", "models/m",
        "--public_key", "docs/models/key.pub.pem",
        "--signature", "docs/models/m.sig",
        "--ignore-paths", "models/m/.cache",
    ]  # fmt: skip
