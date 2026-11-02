"""Shred order on next contact (ADR 0012, threat model T18). A revoked phone that sends a genuinely
signed request is told, in an order signed by the server, to destroy every mission it holds. The
phone checks the signature against the server key pinned in the app (Phase 8) and that the order
names its own device id. The phone holds only its own user's missions, so the order covers all of
them; per-mission orders can come with the mission store (Phase 5)."""

import base64

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from missioncopilot_backend.errors import problem

SHRED_DOMAIN = b"missioncopilot-shred-v1\n"
SHRED_PROBLEM = "urn:missioncopilot:problem:shred-order"
SCOPE = "all-missions"


def shred_message(device_id: str, issued_at: int) -> bytes:
    """The exact bytes the server signs and the phone checks."""
    return SHRED_DOMAIN + "\n".join([device_id, SCOPE, str(issued_at)]).encode()


class ShredOrder(Exception):
    """Raised by the device check for a revoked phone; answered as a signed 410."""

    def __init__(self, device_id: str, issued_at: int):
        super().__init__(device_id)
        self.device_id = device_id
        self.issued_at = issued_at


def _answer(request: Request, exc: Exception) -> JSONResponse:
    key: ec.EllipticCurvePrivateKey = request.app.state.shred_key
    if not isinstance(exc, ShredOrder):
        return problem(500)
    signature = key.sign(shred_message(exc.device_id, exc.issued_at), ec.ECDSA(hashes.SHA256()))
    order = {"deviceId": exc.device_id, "scope": SCOPE, "issuedAt": exc.issued_at}
    return problem(
        410,
        "This phone was revoked: destroy every mission on it.",
        type=SHRED_PROBLEM,
        order=order,
        signature=base64.b64encode(signature).decode(),
    )


def install_shred_orders(app: FastAPI, key: ec.EllipticCurvePrivateKey | None) -> None:
    app.state.shred_key = key  # None: revoked phones keep getting 401 (fail closed)
    app.add_exception_handler(ShredOrder, _answer)
