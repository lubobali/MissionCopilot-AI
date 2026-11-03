"""The server's signing key (#89): one P-256 key that signs mission packs and shred orders. It is
made once into a file only its owner can read, and the server loads nothing else: not a file others
can read, not another kind of key, not a locked or broken file."""

import os
import stat

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

from missioncopilot_backend.signing_key import SigningKeyError, load_signing_key, new_signing_key

pytestmark = pytest.mark.unit


def _write(path, key, encryption=None, mode=0o600):
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        encryption or serialization.NoEncryption(),
    )
    path.write_bytes(pem)
    os.chmod(path, mode)
    return path


def test_a_new_key_is_p256_in_an_owner_only_file(tmp_path):
    path = tmp_path / "keys" / "signing-key.pem"

    public = new_signing_key(path)

    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert isinstance(public.curve, ec.SECP256R1)
    assert b"PRIVATE KEY" in path.read_bytes()  # PKCS#8 PEM


def test_the_loaded_key_is_the_one_that_was_made(tmp_path):
    path = tmp_path / "signing-key.pem"
    public = new_signing_key(path)

    assert load_signing_key(path).public_key() == public


def test_an_existing_key_is_never_overwritten(tmp_path):
    path = tmp_path / "signing-key.pem"
    new_signing_key(path)
    before = path.read_bytes()

    with pytest.raises(SigningKeyError, match="already exists"):
        new_signing_key(path)
    assert path.read_bytes() == before


def test_a_key_file_others_can_read_is_refused(tmp_path):
    path = _write(tmp_path / "k.pem", ec.generate_private_key(ec.SECP256R1()), mode=0o644)

    with pytest.raises(SigningKeyError, match="readable by others"):
        load_signing_key(path)


@pytest.mark.parametrize(
    "key",
    [
        rsa.generate_private_key(public_exponent=65537, key_size=2048),
        ec.generate_private_key(ec.SECP384R1()),
    ],
)
def test_any_other_kind_of_key_is_refused(tmp_path, key):
    with pytest.raises(SigningKeyError, match="P-256"):
        load_signing_key(_write(tmp_path / "k.pem", key))


def test_a_password_locked_key_is_refused(tmp_path):
    locked = serialization.BestAvailableEncryption(b"a password")
    path = _write(tmp_path / "k.pem", ec.generate_private_key(ec.SECP256R1()), locked)

    with pytest.raises(SigningKeyError, match="cannot read"):
        load_signing_key(path)


def test_a_broken_file_is_refused(tmp_path):
    path = tmp_path / "k.pem"
    path.write_text("not a key")
    os.chmod(path, 0o600)

    with pytest.raises(SigningKeyError, match="cannot read"):
        load_signing_key(path)


def test_a_missing_file_is_refused(tmp_path):
    with pytest.raises(SigningKeyError, match="no signing key"):
        load_signing_key(tmp_path / "none.pem")
