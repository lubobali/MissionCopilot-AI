import os
from collections.abc import Mapping
from typing import TypedDict

from missioncopilot_backend.settings import Settings

GRACEFUL_SHUTDOWN_SECONDS = 20  # below the container's stop grace period, so requests can finish


class UvicornOptions(TypedDict):
    host: str
    port: int
    proxy_headers: bool
    forwarded_allow_ips: list[str]
    server_header: bool
    timeout_graceful_shutdown: int


def uvicorn_options(settings: Settings) -> UvicornOptions:
    """How uvicorn serves this backend, from the settings only: where it listens, the one proxy it
    believes (or none), no server software header."""
    trusted = list(settings.forwarded_allow_ips)
    return {
        "host": settings.host,
        "port": settings.port,
        "proxy_headers": bool(trusted),
        "forwarded_allow_ips": trusted,
        "server_header": False,
        "timeout_graceful_shutdown": GRACEFUL_SHUTDOWN_SECONDS,
    }


def main(env: Mapping[str, str] = os.environ) -> None:
    """The one way to run the server, on a laptop and in the container. The factory checks every
    database before serving (server.build); it refuses to start without."""
    import uvicorn

    options = uvicorn_options(Settings.from_env(env))
    uvicorn.run("missioncopilot_backend.server:build", factory=True, **options)
