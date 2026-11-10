"""A software passkey for tests (#174): makes the same "none" attestations and assertions a Mac's
Touch ID passkey makes (WebAuthn Level 3), with a P-256 key and a counter, so the server's checks
run on real bytes. Flags can be changed to test what the server refuses."""

import base64
import hashlib
import json
import secrets
import struct

import cbor2
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

UP, UV, AT = 0x01, 0x04, 0x40


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class SoftAuthenticator:
    def __init__(self, rp_id: str, origin: str, sign_count: int = 0):
        self.rp_id, self.origin, self.sign_count = rp_id, origin, sign_count
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.credential_id = secrets.token_bytes(16)
        self.user_handle = b""

    def _cose(self) -> bytes:
        numbers = self.key.public_key().public_numbers()
        x, y = numbers.x.to_bytes(32, "big"), numbers.y.to_bytes(32, "big")
        return cbor2.dumps({1: 2, 3: -7, -1: 1, -2: x, -3: y})

    def _client_data(self, kind: str, challenge: str, origin: str | None) -> bytes:
        return json.dumps({"type": kind, "challenge": challenge, "origin": origin or self.origin,
                           "crossOrigin": False}).encode()  # fmt: skip

    def create(self, options_json: str, flags: int = UP | UV, origin: str | None = None) -> dict:
        options = json.loads(options_json)
        self.user_handle = unb64url(options["user"]["id"])
        rp_hash = hashlib.sha256(self.rp_id.encode()).digest()
        attested = bytes(16) + struct.pack(">H", len(self.credential_id)) + self.credential_id
        auth_data = rp_hash + bytes([flags | AT]) + struct.pack(">I", self.sign_count)
        auth_data += attested + self._cose()
        attestation = cbor2.dumps({"fmt": "none", "attStmt": {}, "authData": auth_data})
        client = self._client_data("webauthn.create", options["challenge"], origin)
        response = {"clientDataJSON": b64url(client), "attestationObject": b64url(attestation),
                    "transports": ["internal"]}  # fmt: skip
        return self._credential(response)

    def _credential(self, response: dict) -> dict:
        cid = b64url(self.credential_id)
        return {"id": cid, "rawId": cid, "type": "public-key", "clientExtensionResults": {},
                "response": response}  # fmt: skip

    def get(self, options_json: str, flags: int = UP | UV, origin: str | None = None,
            count: int | None = None) -> dict:  # fmt: skip
        options = json.loads(options_json)
        self.sign_count = self.sign_count + 1 if count is None else count
        rp_hash = hashlib.sha256(self.rp_id.encode()).digest()
        auth_data = rp_hash + bytes([flags]) + struct.pack(">I", self.sign_count)
        client = self._client_data("webauthn.get", options["challenge"], origin)
        signature = self.key.sign(auth_data + hashlib.sha256(client).digest(),
                                  ec.ECDSA(hashes.SHA256()))  # fmt: skip
        return self._credential({
            "clientDataJSON": b64url(client), "authenticatorData": b64url(auth_data),
            "signature": b64url(signature), "userHandle": b64url(self.user_handle),
        })  # fmt: skip
