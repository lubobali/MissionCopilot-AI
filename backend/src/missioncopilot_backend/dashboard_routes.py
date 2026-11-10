"""The manager dashboard's sign-in (#174, step 8.4.3; ADR 0014). JSON routes the dashboard's own
script calls: register a passkey from the one-time invite, sign in with it, sign out. A signed-in
manager holds a session cookie: __Host- prefix, Secure, HttpOnly, SameSite=Strict, 8 hours (OWASP's
strongest form); the phone never uses cookies, it signs every request. Every POST must carry the
dashboard's own Origin (OWASP's CSRF check, on top of SameSite). With no dashboard address
configured, every route here is 404."""

from typing import Any
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import Field

from missioncopilot_backend.auth import audit
from missioncopilot_backend.dashboard_auth import SESSION_SECONDS, DashboardStore, DashboardUser
from missioncopilot_backend.models import StrictModel
from missioncopilot_backend.passkeys import (
    PasskeyRefused,
    Site,
    authentication_options,
    registration_options,
    verify_authentication,
    verify_registration,
)

COOKIE = "__Host-mc_session"
REFUSED = HTTPException(401)


def site(request: Request) -> Site:
    """The dashboard's site, or 404 when this server has none."""
    origin = request.app.state.settings.dashboard_origin
    if not origin:
        raise HTTPException(404)
    return Site(rp_id=urlsplit(origin).hostname or "", origin=origin)


def same_origin(request: Request, here: Site = Depends(site)) -> Site:
    """A POST must come from the dashboard's own pages (the Origin header), or it is 403."""
    if request.headers.get("origin") != here.origin:
        raise HTTPException(403)
    return here


def _store(request: Request) -> DashboardStore:
    return request.app.state.dashboard


def require_manager(request: Request) -> DashboardUser:
    """The signed-in manager, from the stored session only; anything else is 401."""
    token = request.cookies.get(COOKIE)
    user = _store(request).session(token) if token else None
    if user is None:
        raise REFUSED
    return user


def _signed_in(request: Request, response: Response, user: DashboardUser) -> None:
    token = _store(request).new_session(user.id)
    response.set_cookie(COOKIE, token, max_age=SESSION_SECONDS, path="/", secure=True,
                        httponly=True, samesite="strict")  # fmt: skip
    audit(request, "dashboard_signed_in", user.org_id, user.user_id)


class InviteIn(StrictModel):
    code: str = Field(min_length=1, max_length=64)


class CredentialIn(StrictModel):
    credential: dict[str, Any]


router = APIRouter(prefix="/v1/dashboard")  # the JSON API; the pages live at /dashboard (8.4.4)


@router.post("/register/options")
def register_options(
    body: InviteIn, request: Request, here: Site = Depends(same_origin)
) -> Response:
    try:
        options = registration_options(_store(request), body.code, here)
    except PasskeyRefused:
        raise REFUSED from None
    return Response(options, media_type="application/json")


@router.post("/register/verify", status_code=201)
def register_verify(
    body: CredentialIn, request: Request, response: Response, here: Site = Depends(same_origin)
) -> dict[str, str]:
    try:
        user = verify_registration(_store(request), body.credential, here)
    except PasskeyRefused:
        audit(request, "dashboard_sign_in_failed")
        raise REFUSED from None
    audit(request, "passkey_added", user.org_id, user.user_id)
    _signed_in(request, response, user)
    return {"name": user.name}


@router.post("/sign-in/options")
def sign_in_options(request: Request, here: Site = Depends(same_origin)) -> Response:
    return Response(authentication_options(_store(request), here), media_type="application/json")


@router.post("/sign-in/verify")
def sign_in_verify(
    body: CredentialIn, request: Request, response: Response, here: Site = Depends(same_origin)
) -> dict[str, str]:
    try:
        user = verify_authentication(_store(request), body.credential, here)
    except PasskeyRefused:
        audit(request, "dashboard_sign_in_failed")
        raise REFUSED from None
    _signed_in(request, response, user)
    return {"name": user.name}


@router.post("/sign-out", dependencies=[Depends(same_origin)])
def sign_out(request: Request) -> RedirectResponse:
    token = request.cookies.get(COOKIE)
    if token:
        _store(request).end_session(token)
    response = RedirectResponse("/dashboard/sign-in", status_code=303)
    response.delete_cookie(COOKIE, path="/", secure=True, httponly=True, samesite="strict")
    return response


@router.get("/me")
def me(user: DashboardUser = Depends(require_manager)) -> dict[str, object]:
    return {"name": user.name, "org": user.org_id, "user": user.user_id, "roles": list(user.roles)}


def dashboard_routes() -> list[APIRouter]:
    return [router]
