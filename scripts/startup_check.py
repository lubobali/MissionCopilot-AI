"""Prove the backend imports and builds its routes, the way the server would load it.

Usage: uv run --directory backend python ../scripts/startup_check.py
The server itself is a factory (missioncopilot_backend.server:build) that refuses to start without
its databases, so this checks that the factory imports and that the app builds every route. CI runs
it with no real secrets.
"""

import importlib
import sys

FACTORY_PATH = "missioncopilot_backend.server:build"


def check_factory(path: str) -> tuple[bool, str]:
    module_name, _, attr = path.partition(":")
    try:
        module = importlib.import_module(module_name)
    except ImportError as exc:
        return False, f"FAIL: cannot import {module_name}: {exc}"
    factory = getattr(module, attr, None)
    if not callable(factory):
        return False, f"FAIL: {module_name} has no factory {attr}"
    return True, f"OK: {path} loads"


def check_routes() -> tuple[bool, str]:
    from missioncopilot_backend.app import create_app
    from missioncopilot_backend.settings import Settings

    routes = len(create_app(Settings()).routes)
    return routes > 0, f"OK: app builds {routes} routes" if routes else "FAIL: no routes"


def main() -> int:
    results = [check_factory(FACTORY_PATH), check_routes()]
    for _, message in results:
        print(message)
    return 0 if all(ok for ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())
