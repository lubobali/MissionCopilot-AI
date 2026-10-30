"""Prove the backend app imports and builds its routes, the way the server would load it.

Usage: uv run --directory backend python ../scripts/startup_check.py
CI runs this with dummy env values only, never real secrets.
"""

import importlib
import sys

APP_PATH = "missioncopilot_backend.app:app"


def check_app(app_path: str) -> tuple[bool, str]:
    module_name, _, attr = app_path.partition(":")
    try:
        module = importlib.import_module(module_name)
    except ImportError as exc:
        return False, f"FAIL: cannot import {module_name}: {exc}"
    app = getattr(module, attr, None)
    if app is None:
        return False, f"FAIL: {module_name} has no attribute {attr}"
    return True, f"OK: app loaded with {len(app.routes)} routes"


def main() -> int:
    ok, message = check_app(APP_PATH)
    print(message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
