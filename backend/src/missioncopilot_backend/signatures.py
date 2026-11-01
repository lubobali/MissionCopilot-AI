"""Secure Enclave signatures as the phone makes them (spike #17): ECDSA P-256 over SHA-256, DER
encoded (CryptoKit derRepresentation), public keys as SubjectPublicKeyInfo DER. Shared by the
evidence chain and device enrollment, so both check signatures the same way."""

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def load_p256_public_key(public_key_der: bytes) -> ec.EllipticCurvePublicKey | None:
    """The key, or None if the bytes are not a P-256 public key."""
    try:
        key = serialization.load_der_public_key(public_key_der)
    except ValueError:
        return None
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        return None
    return key


def is_signed_by(key: ec.EllipticCurvePublicKey, signature: bytes, message: bytes) -> bool:
    try:
        key.verify(signature, message, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        return False
    return True
