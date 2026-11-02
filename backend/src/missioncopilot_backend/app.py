import os
import time
from collections.abc import Callable

from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.auth import TokenVerifier
from missioncopilot_backend.device_routes import device_routes
from missioncopilot_backend.devices import DeviceRegistry, EnrollmentCodes
from missioncopilot_backend.errors import install_error_handlers
from missioncopilot_backend.headers import SecurityHeadersMiddleware
from missioncopilot_backend.limits import LimitsMiddleware, RateLimiter
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.shred_order import install_shred_orders
from missioncopilot_backend.tenancy import OrgDatabases

v1 = APIRouter(prefix="/v1")


@v1.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def create_app(
    settings: Settings,
    verifier: TokenVerifier | None = None,
    databases: OrgDatabases | None = None,
    clock: Callable[[], float] = time.monotonic,
    audit: AuditLog | None = None,
    enrollment_codes: EnrollmentCodes | None = None,
    devices: DeviceRegistry | None = None,
    shred_key: ec.EllipticCurvePrivateKey | None = None,
) -> FastAPI:
    """Build the app for one set of settings; tests build their own instead of patching globals."""
    docs = settings.docs_enabled
    app = FastAPI(
        title="MissionCopilot-AI backend",
        docs_url="/docs" if docs else None,
        redoc_url="/redoc" if docs else None,
        openapi_url="/openapi.json" if docs else None,
    )
    app.state.verifier = verifier  # None: every secured route refuses (fail closed)
    app.state.databases = databases  # None: every organization's data answers 404
    app.state.audit = audit = audit or AuditLog()
    app.state.enrollment_codes = enrollment_codes or EnrollmentCodes()
    app.state.devices = devices or DeviceRegistry()
    install_error_handlers(app)
    install_shred_orders(app, shred_key)
    # Middleware runs outermost last-added: headers on every answer, then the host check, the
    # limits, and browser origins closest to the routes.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.allowed_origins),
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
        allow_credentials=False,  # bearer tokens, never cookies
        max_age=600,
    )
    limiter = RateLimiter(settings.rate_limit_per_minute, clock=clock)
    app.add_middleware(
        LimitsMiddleware, limiter=limiter, max_body_bytes=settings.max_body_bytes, audit=audit
    )
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=list(settings.allowed_hosts))
    docs_pages = frozenset({"/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"})
    app.add_middleware(
        SecurityHeadersMiddleware,
        hsts=settings.environment == "production",
        policy_exempt_paths=docs_pages if docs else frozenset(),
    )
    app.include_router(v1)
    for router in device_routes():
        app.include_router(router)
    return app


# What the server (uvicorn) and the startup check load.
app = create_app(Settings.from_env(os.environ))
