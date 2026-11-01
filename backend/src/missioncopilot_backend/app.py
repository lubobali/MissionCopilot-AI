import os

from fastapi import APIRouter, FastAPI

from missioncopilot_backend.settings import Settings

v1 = APIRouter(prefix="/v1")


@v1.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def create_app(settings: Settings) -> FastAPI:
    """Build the app for one set of settings; tests build their own instead of patching globals."""
    docs = settings.docs_enabled
    app = FastAPI(
        title="MissionCopilot-AI backend",
        docs_url="/docs" if docs else None,
        redoc_url="/redoc" if docs else None,
        openapi_url="/openapi.json" if docs else None,
    )
    app.include_router(v1)
    return app


# What the server (uvicorn) and the startup check load.
app = create_app(Settings.from_env(os.environ))
