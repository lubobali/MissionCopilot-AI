import time
from collections.abc import Callable

from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from starlette.types import Lifespan

from missioncopilot_backend.app_version import AppVersionMiddleware
from missioncopilot_backend.approval_keys import ApprovalKeys, ApprovalKeyStore
from missioncopilot_backend.audit import AuditLog, AuditStore
from missioncopilot_backend.auth import TokenVerifier
from missioncopilot_backend.dashboard_auth import DashboardMemory, DashboardStore
from missioncopilot_backend.dashboard_pages import install_dashboard_pages
from missioncopilot_backend.dashboard_routes import dashboard_routes
from missioncopilot_backend.device_routes import device_routes
from missioncopilot_backend.devices import CodeStore, DeviceRegistry, DeviceStore, EnrollmentCodes
from missioncopilot_backend.errors import install_error_handlers
from missioncopilot_backend.headers import SecurityHeadersMiddleware
from missioncopilot_backend.limits import DeviceLimits, LimitsMiddleware, RateLimiter
from missioncopilot_backend.mission_routes import mission_routes
from missioncopilot_backend.pack_routes import pack_routes
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.shred_order import install_shred_orders
from missioncopilot_backend.sync_routes import sync_routes
from missioncopilot_backend.tenancy import OrgStores

v1 = APIRouter(prefix="/v1")


@v1.get("/health")
def health(request: Request) -> dict[str, str | int]:
    """Alive, and the server's time in Unix seconds: the clock the signed-request window uses, so a
    phone measures its own clock's offset here (no database is touched)."""
    devices: DeviceStore = request.app.state.devices
    return {"status": "ok", "time": int(devices.now())}


@v1.get("/ready")
def ready(request: Request) -> dict[str, str]:
    """Can serve: the directory database answers (health only says the process is alive). 503
    with Retry-After when it does not, so a deploy or a monitor waits (#103 step 4.5)."""
    if not request.app.state.ready():
        raise HTTPException(503, headers={"Retry-After": "5"})
    return {"status": "ready"}


def create_app(
    settings: Settings,
    verifier: TokenVerifier | None = None,
    databases: OrgStores | None = None,
    clock: Callable[[], float] = time.monotonic,
    audit: AuditStore | None = None,
    enrollment_codes: CodeStore | None = None,
    devices: DeviceStore | None = None,
    approval_keys: ApprovalKeyStore | None = None,
    dashboard: DashboardStore | None = None,
    signing_key: ec.EllipticCurvePrivateKey | None = None,
    lifespan: Lifespan | None = None,
    ready: Callable[[], bool] | None = None,
) -> FastAPI:
    """Build the app for one set of settings; tests build their own instead of patching globals."""
    docs = settings.docs_enabled
    app = FastAPI(
        title="MissionCopilot-AI backend",
        docs_url="/docs" if docs else None,
        redoc_url="/redoc" if docs else None,
        openapi_url="/openapi.json" if docs else None,
        lifespan=lifespan,
    )
    app.state.ready = ready or (lambda: True)  # in memory: nothing outside to wait for
    app.state.verifier = verifier  # None: every secured route refuses (fail closed)
    app.state.databases = databases  # None: every organization's data answers 404
    app.state.audit = audit = audit or AuditLog()
    app.state.enrollment_codes = enrollment_codes or EnrollmentCodes()
    app.state.devices = devices or DeviceRegistry()
    app.state.approval_keys = approval_keys or ApprovalKeys()  # #171
    app.state.dashboard = dashboard or DashboardMemory()  # #174
    app.state.settings = settings
    app.state.device_limits = DeviceLimits(
        RateLimiter(settings.device_rate_limit_per_minute, clock=clock)
    )
    install_error_handlers(app)
    install_shred_orders(app, signing_key)
    # Middleware runs outermost last-added: headers on every answer, then the host check, the
    # limits, browser origins, and the phone's app build closest to the routes.
    app.add_middleware(AppVersionMiddleware, min_build=settings.min_app_build)
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
    for router in [*mission_routes(), *pack_routes(), *sync_routes(), *dashboard_routes()]:
        app.include_router(router)
    install_dashboard_pages(app)  # #174: the pages and their static files
    return app
