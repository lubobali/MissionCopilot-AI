"""Database migrations (#88): numbered SQL files, each run once and in order, in its own transaction
together with its record. A file edited after it ran, or a database that has a migration this code
does not know, stops the start (fail closed). Two servers starting at once take turns on a lock.

Plain SQL on purpose: there is no ORM here, and row-level security reads best as the SQL itself."""

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

import psycopg

NAME = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")
LOCK = 0x4D43_4D49  # pg_advisory_lock key ("MCMI"): one migration run at a time per database

RECORDS = b"""
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    integer PRIMARY KEY,
    name       text NOT NULL,
    sha256     text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
)"""


class MigrationError(Exception):
    """The migration files or the database are not in a state we can safely start from."""


@dataclass(frozen=True)
class Migration:
    version: int
    name: str
    sql: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.sql.encode()).hexdigest()


def load(folder: Path) -> list[Migration]:
    """The .sql files in a folder, numbered 0001, 0002, ... with no gap and no repeat."""
    migrations = []
    for path in folder.glob("*.sql"):
        match = NAME.match(path.name)
        if not match:
            raise MigrationError(f"{path.name}: name it NNNN_lowercase_words.sql")
        migrations.append(Migration(int(match[1]), path.name, path.read_text(encoding="utf-8")))
    migrations.sort(key=lambda m: m.version)
    for expected, migration in enumerate(migrations, start=1):
        if migration.version < expected:
            raise MigrationError(f"number {migration.version:04d} is used twice")
        if migration.version > expected:
            raise MigrationError(f"{expected:04d} is missing")
    return migrations


def _check(done: dict[int, tuple[str, str]], migrations: list[Migration]) -> None:
    known = {m.version: m for m in migrations}
    for version, (name, sha256) in sorted(done.items()):
        migration = known.get(version)
        if migration is None:
            raise MigrationError(f"the database has {name}, which this code does not know")
        if (migration.name, migration.sha256) != (name, sha256):
            raise MigrationError(f"{name} was edited after it ran; add a new migration instead")


def migrate(url: str, migrations: list[Migration]) -> list[int]:
    """Run the pending migrations; returns the versions it applied (none: [])."""
    with psycopg.connect(url, autocommit=True) as conn:
        # A session lock: a second server waits here, and closing the connection releases it.
        conn.execute("SELECT pg_advisory_lock(%s)", [LOCK])
        conn.execute(RECORDS)
        rows = conn.execute("SELECT version, name, sha256 FROM schema_migrations").fetchall()
        done = {version: (name, sha256) for version, name, sha256 in rows}
        _check(done, migrations)
        applied = []
        for migration in migrations:
            if migration.version in done:
                continue
            with conn.transaction():
                conn.execute(migration.sql.encode())
                conn.execute(
                    "INSERT INTO schema_migrations (version, name, sha256) VALUES (%s, %s, %s)",
                    [migration.version, migration.name, migration.sha256],
                )
            applied.append(migration.version)
        return applied
