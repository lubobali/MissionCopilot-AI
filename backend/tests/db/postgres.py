"""Throwaway Postgres databases for tests (#88). The server address comes from
MISSIONCOPILOT_TEST_ADMIN_URL (CI sets it) or backend/.env (scripts/make_dev_env.py writes it)."""

import os
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

from missioncopilot_backend.settings import read_env_file

ENV_FILE = Path(__file__).resolve().parents[2] / ".env"
HOW_TO_START = (
    "No test Postgres. Once: uv run --directory backend python ../scripts/make_dev_env.py; "
    "then: docker compose --project-directory backend up -d --wait"
)


def admin_url(env_file: Path = ENV_FILE) -> str:
    url = os.environ.get("MISSIONCOPILOT_TEST_ADMIN_URL") or read_env_file(env_file).get(
        "MISSIONCOPILOT_TEST_ADMIN_URL"
    )
    if not url:
        raise RuntimeError(HOW_TO_START)
    return url


@contextmanager
def throwaway_database() -> Generator[str]:
    """A new empty database; yields its address and drops it afterwards, even if a test left a
    connection open."""
    name = f"mc_test_{uuid.uuid4().hex}"
    with psycopg.connect(admin_url(), autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
    try:
        yield make_conninfo(admin_url(), dbname=name)
    finally:
        with psycopg.connect(admin_url(), autocommit=True) as admin:
            admin.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))
