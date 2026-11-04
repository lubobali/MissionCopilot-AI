"""The real server (#88): everything from the environment, and nothing served until every database
checks out. Fail closed: a missing address, a secret file others can read, an organization without
its own database address, an address into the wrong database, a wrong password or a database behind
the code all stop the start with a message saying what to fix. The server never migrates by itself;
an operator does (scripts/admin.py), then starts it.

Settings, each VAR or VAR_FILE (a file holding the value, for container secrets), never both:
  MISSIONCOPILOT_DIRECTORY_URL  the directory database (organizations, phones, codes, audit log)
  MISSIONCOPILOT_ORG_URLS_DIR   a folder with <org id>.url per organization: its app login's address
And, as a file only (a private key never travels in an environment variable):
  MISSIONCOPILOT_SIGNING_KEY_FILE  the P-256 key that signs mission packs and shred orders
"""

import os
from collections.abc import AsyncGenerator, Mapping
from contextlib import ExitStack, asynccontextmanager
from pathlib import Path

import psycopg
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI
from psycopg.conninfo import conninfo_to_dict
from psycopg_pool import ConnectionPool

from missioncopilot_backend.app import create_app
from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.migrations import MigrationError, load, pending
from missioncopilot_backend.db.missions import ORG_MIGRATIONS, PostgresOrgDatabases
from missioncopilot_backend.settings import Settings
from missioncopilot_backend.signing_key import SigningKeyError, load_signing_key

DIRECTORY = "MISSIONCOPILOT_DIRECTORY_URL"
ORG_URLS_DIR = "MISSIONCOPILOT_ORG_URLS_DIR"
SIGNING_KEY = "MISSIONCOPILOT_SIGNING_KEY"


class StartupError(Exception):
    """The server must not start; the message says what to fix."""


def _private_text(path: Path) -> str:
    if path.stat().st_mode & 0o077:
        raise StartupError(f"{path} is readable by others; chmod 600 it")
    return path.read_text(encoding="utf-8").strip()


def read_setting(env: Mapping[str, str], name: str) -> str:
    value, file = env.get(name), env.get(f"{name}_FILE")
    if value and file:
        raise StartupError(f"set {name} or {name}_FILE, not both")
    if file:
        return _private_text(Path(file))
    if not value:
        raise StartupError(f"set {name} (or {name}_FILE)")
    return value


def _org_urls(env: Mapping[str, str]) -> dict[str, str]:
    folder = Path(read_setting(env, ORG_URLS_DIR))
    return {path.stem: _private_text(path) for path in sorted(folder.glob("*.url"))}


def _check_migrated(what: str, url: str, folder: Path) -> None:
    try:
        missing = pending(url, load(folder))
    except psycopg.OperationalError as error:
        raise StartupError(f"{what}: cannot connect ({error.__class__.__name__})") from None
    except MigrationError as error:
        raise StartupError(f"{what}: {error}") from None
    if missing:
        raise StartupError(f"{what} lacks migrations {missing}; run the migrations first")


def _org_pools(
    directory: Directory, urls: dict[str, str], stack: ExitStack
) -> PostgresOrgDatabases:
    databases = directory.organizations()
    for org_id in urls.keys() - databases.keys():
        raise StartupError(f"{org_id} is not in the directory; remove its .url file")
    pools = {}
    for org_id, database in sorted(databases.items()):
        url = urls.get(org_id)
        if url is None:
            raise StartupError(f"no database address for {org_id} in {ORG_URLS_DIR}")
        named = conninfo_to_dict(url).get("dbname")
        if named != database:
            raise StartupError(f"the address for {org_id} points at {named}, not {database}")
        _check_migrated(f"database of {org_id}", url, ORG_MIGRATIONS)
        pools[org_id] = stack.enter_context(ConnectionPool(url, min_size=1, max_size=8, open=True))
    return PostgresOrgDatabases(pools)


def _signing_key(env: Mapping[str, str]) -> ec.EllipticCurvePrivateKey:
    if env.get(SIGNING_KEY):
        raise StartupError(f"{SIGNING_KEY} is not read; give the key as a file: {SIGNING_KEY}_FILE")
    file = env.get(f"{SIGNING_KEY}_FILE")
    if not file:
        raise StartupError(f"set {SIGNING_KEY}_FILE (missioncopilot-admin make-signing-key)")
    try:
        return load_signing_key(Path(file))
    except SigningKeyError as error:
        raise StartupError(str(error)) from None


def build(env: Mapping[str, str] = os.environ) -> FastAPI:
    """The server for this environment; raises StartupError instead of starting half-ready."""
    settings = Settings.from_env(env)
    if problems := settings.unsafe():
        raise StartupError("; ".join(problems))
    signing_key = _signing_key(env)
    directory_url = read_setting(env, DIRECTORY)
    urls = _org_urls(env)
    _check_migrated("the directory", directory_url, Directory.MIGRATIONS)
    stack = ExitStack()
    try:
        directory = stack.enter_context(Directory.open(directory_url, migrations=False))
        databases = _org_pools(directory, urls, stack)
    except BaseException:
        stack.close()
        raise

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncGenerator[None]:
        with stack:  # closes every pool when the server stops
            yield

    return create_app(
        settings,
        databases=databases,
        audit=directory.audit,
        enrollment_codes=directory.codes,
        devices=directory.devices,
        signing_key=signing_key,
        lifespan=lifespan,
    )
