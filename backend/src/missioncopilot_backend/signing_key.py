"""The server's signing key (#89): one ECDSA P-256 key that signs mission packs and shred orders,
each with its own domain label so one can never pass as the other. The app pins its public half by
key id (pack_format.key_id).

It lives in one file only its owner can read, made once by missioncopilot-admin make-signing-key
and never overwritten. The server loads nothing else: not a file others can read, not another kind
of key, not a password-locked or broken file. Production would keep it in a hardware key store
(HSM or cloud KMS): that is the deployment hardening in Iteration 9."""

import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


class SigningKeyError(Exception):
    """The signing key cannot be made or used; the message says what to fix."""


def new_signing_key(path: Path) -> ec.EllipticCurvePublicKey:
    """A new key in an owner-only file (never over an existing one); returns its public half."""
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise SigningKeyError(f"{path} already exists; not overwriting a signing key") from None
    with os.fdopen(descriptor, "wb") as file:
        file.write(pem)
    return key.public_key()


def load_signing_key(path: Path) -> ec.EllipticCurvePrivateKey:
    if not path.exists():
        raise SigningKeyError(
            f"no signing key at {path}; run missioncopilot-admin make-signing-key"
        )
    if path.stat().st_mode & 0o077:  # checked before a single byte of the key is read
        raise SigningKeyError(f"{path} is readable by others; chmod 600 it")
    try:
        pem = path.read_bytes()
    except OSError as error:  # a folder, or owned by someone else (a container's root)
        raise SigningKeyError(
            f"{path} cannot be read ({error.strerror or error.__class__.__name__}); it must be a "
            f"file owned by this process's user (uid {os.getuid()}), chmod 600"
        ) from None
    try:
        key = serialization.load_pem_private_key(pem, password=None)
    except (ValueError, TypeError):
        raise SigningKeyError(f"cannot read the signing key in {path}") from None
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        raise SigningKeyError(f"{path} is not a P-256 key")
    return key
