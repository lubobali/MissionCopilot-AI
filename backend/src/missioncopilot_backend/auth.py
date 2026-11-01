"""Who is calling (threat model T30, T31). Every route outside health sits on a secured router and
needs a bearer token signed with ES256 by the configured issuer; the organization and user come only
from that token. Any failure answers the same 401, so a caller cannot learn which check failed. With
no verifier configured, every request is refused (fail closed)."""

from collections.abc import Callable
from dataclasses import dataclass, field

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request

from missioncopilot_backend.audit import AuditLog, Kind

REQUIRED_CLAIMS = ["iss", "aud", "sub", "org", "iat", "exp"]


@dataclass(frozen=True)
class Principal:
    org_id: str
    user_id: str
    roles: frozenset[str] = field(default_factory=frozenset)


class TokenVerifier:
    def __init__(
        self, public_key_pem: str, *, issuer: str, audience: str, leeway_seconds: int = 30
    ):
        self._key = public_key_pem
        self._issuer = issuer
        self._audience = audience
        self._leeway = leeway_seconds

    def verify(self, token: str) -> Principal:
        """Raises jwt.InvalidTokenError for any problem."""
        claims = jwt.decode(
            token,
            self._key,
            algorithms=["ES256"],  # one algorithm only: no "none", no HMAC confusion
            issuer=self._issuer,
            audience=self._audience,
            leeway=self._leeway,
            options={"require": REQUIRED_CLAIMS},
        )
        org, user = claims["org"], claims["sub"]
        if not isinstance(org, str) or not org or not isinstance(user, str) or not user:
            raise jwt.InvalidTokenError("organization and subject must be non-empty strings")
        roles = claims.get("roles", [])
        if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
            raise jwt.InvalidTokenError("roles must be a list of names")
        return Principal(org_id=org, user_id=user, roles=frozenset(roles))


UNAUTHORIZED = HTTPException(401, headers={"WWW-Authenticate": "Bearer"})


def audit(
    request: Request,
    kind: Kind,
    org_id: str | None = None,
    actor: str | None = None,
    subject: str | None = None,
) -> None:
    log: AuditLog | None = getattr(request.app.state, "audit", None)
    if log is not None:
        client = request.client.host if request.client else None
        log.record(kind, client=client, org_id=org_id, actor=actor, subject=subject)


def require_principal(request: Request) -> Principal:
    verifier: TokenVerifier | None = getattr(request.app.state, "verifier", None)
    scheme, _, token = request.headers.get("Authorization", "").partition(" ")
    if verifier is None or scheme != "Bearer" or not token:
        audit(request, "auth_failed")
        raise UNAUTHORIZED
    try:
        return verifier.verify(token)
    except jwt.InvalidTokenError:
        audit(request, "auth_failed")
        raise UNAUTHORIZED from None


def require_role(*allowed: str) -> Callable[..., Principal]:
    """A dependency for an action only some roles may take (API5:2023): 403 otherwise, recorded."""

    def check(request: Request, principal: Principal = Depends(require_principal)) -> Principal:
        if not principal.roles & set(allowed):
            audit(request, "role_denied", org_id=principal.org_id, actor=principal.user_id)
            raise HTTPException(403)
        return principal

    return check


def secured_router() -> APIRouter:
    """The router for every non-public route: authentication is the default, not an opt-in."""
    return APIRouter(prefix="/v1", dependencies=[Depends(require_principal)])
