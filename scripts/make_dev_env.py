"""Write backend/.env for the local Postgres (#88): a random admin password, the address the
database tests use and the one missioncopilot-admin uses. Run once per machine; an existing file
is never overwritten.

Usage: uv run --directory backend python ../scripts/make_dev_env.py
Then:  docker compose --project-directory backend up -d --wait
The file is gitignored and readable by its owner only. Local development only, never production.
"""

import os
import secrets
import sys
from pathlib import Path

from missioncopilot_backend.settings import read_env_file

PORT = 55432  # backend/compose.yaml publishes Postgres here, on 127.0.0.1 only
ENV_FILE = Path(__file__).resolve().parents[1] / "backend" / ".env"
read_env = read_env_file


def write_dev_env(path: Path = ENV_FILE) -> bool:
    """True if written; False if the file was already there (kept as it is)."""
    if path.exists():
        return False
    password = secrets.token_hex(24)
    url = f"postgresql://missioncopilot_admin:{password}@127.0.0.1:{PORT}/postgres"
    body = (
        "# Local development only (scripts/make_dev_env.py). Never commit, never for production.\n"
        f"MISSIONCOPILOT_PG_ADMIN_PASSWORD={password}\n"
        f"MISSIONCOPILOT_TEST_ADMIN_URL={url}\n"
        f"MISSIONCOPILOT_ADMIN_URL={url}\n"  # missioncopilot-admin, local only
    )
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(body)
    return True


def main() -> int:
    if write_dev_env():
        print(f"OK: wrote {ENV_FILE}")
    else:
        print(f"OK: {ENV_FILE} already exists, kept it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
