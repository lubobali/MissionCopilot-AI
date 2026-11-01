import os
import time
from collections.abc import Callable

from fastapi import APIRouter, FastAPI

from missioncopilot_backend.auth import TokenVerifier
from missioncopilot_backend.errors import install_error_handlers
from missioncopilot_backend.limits import LimitsMiddleware, RateLimiter
from missioncopilot_backend.settings import Settings
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
    install_error_handlers(app)
    limiter = RateLimiter(settings.rate_limit_per_minute, clock=clock)
    app.add_middleware(LimitsMiddleware, limiter=limiter, max_body_bytes=settings.max_body_bytes)
    app.include_router(v1)
    return app


# What the server (uvicorn) and the startup check load.
app = create_app(Settings.from_env(os.environ))
