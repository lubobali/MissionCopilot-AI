"""The directory database (#88): organizations, enrollment codes and devices, the things the server
must find before it knows the caller's organization. Missions never live here.

Same contract as the in-memory stand-ins in devices.py (tests/db/test_directory.py runs both). Two
races are closed by Postgres itself: a code is deleted as it is read (DELETE ... RETURNING), so two
phones cannot both use it, and a request number is raised only if it is higher (one UPDATE), so two
copies of a signed request cannot both pass."""

import hashlib
import secrets
import time
import uuid
from collections.abc import Callable, Generator
from contextlib import contextmanager
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.audit_log import PostgresAuditLog
from missioncopilot_backend.db.migrations import load, migrate
from missioncopilot_backend.db.pools import open_pool
from missioncopilot_backend.devices import CODE_LIFETIME_SECONDS, Device, EnrollmentGrant

READY_TIMEOUT_SECONDS = 2

MIGRATIONS = Path(__file__).parent / "sql" / "directory"
COLUMNS = "id, org_id, user_id, label, public_key_der, status, enrolled_at, last_seq"
UPDATABLE = {"status", "label", "last_seq"}


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _device(row: tuple) -> Device:
    device_id, org_id, user_id, label, key, status, enrolled_at, last_seq = row
    return Device(str(device_id), org_id, user_id, label, bytes(key), status, enrolled_at, last_seq)


def _uuid(device_id: str) -> uuid.UUID | None:
    """A device id comes from a request header: anything that is not a UUID is simply unknown."""
    try:
        return uuid.UUID(device_id)
    except ValueError:
        return None


class PostgresEnrollmentCodes:
    def __init__(self, pool: ConnectionPool, clock: Callable[[], float]):
        self._pool, self._clock = pool, clock

    def issue(self, org_id: str, user_id: str, device_label: str) -> tuple[str, EnrollmentGrant]:
        code = secrets.token_urlsafe(16)
        grant = EnrollmentGrant(
            org_id, user_id, device_label, self._clock() + CODE_LIFETIME_SECONDS
        )
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO enrollment_codes (digest, org_id, user_id, device_label, expires_at)"
                " VALUES (%s, %s, %s, %s, %s)",
                [_digest(code.encode()), org_id, user_id, device_label, grant.expires_at],
            )
        return code, grant

    def consume(self, code: str) -> EnrollmentGrant | None:
        with self._pool.connection() as conn:
            row = conn.execute(
                "DELETE FROM enrollment_codes WHERE digest = %s"
                " RETURNING org_id, user_id, device_label, expires_at",
                [_digest(code.encode())],
            ).fetchone()
        if row is None or self._clock() >= row[3]:
            return None
        return EnrollmentGrant(*row)


class PostgresDeviceRegistry:
    def __init__(self, pool: ConnectionPool, clock: Callable[[], float]):
        self._pool, self._clock = pool, clock

    def now(self) -> float:
        return self._clock()

    def _one(self, query: sql.Composed, params: list[object]) -> Device | None:
        with self._pool.connection() as conn:
            row = conn.execute(query, params).fetchone()
        return _device(row) if row else None

    def find(self, device_id: str) -> Device | None:
        key = _uuid(device_id)
        query = sql.SQL("SELECT {} FROM devices WHERE id = %s").format(sql.SQL(COLUMNS))
        return self._one(query, [key]) if key else None

    def in_org(self, org_id: str, device_id: str) -> Device | None:
        key = _uuid(device_id)
        query = sql.SQL("SELECT {} FROM devices WHERE id = %s AND org_id = %s").format(
            sql.SQL(COLUMNS)
        )
        return self._one(query, [key, org_id]) if key else None

    def of_org(self, org_id: str) -> list[Device]:
        query = sql.SQL(
            "SELECT {} FROM devices WHERE org_id = %s ORDER BY status <> 'pending', enrolled_at"
        ).format(sql.SQL(COLUMNS))
        with self._pool.connection() as conn:
            return [_device(row) for row in conn.execute(query, [org_id]).fetchall()]

    def has_key(self, public_key_der: bytes) -> bool:
        with self._pool.connection() as conn:
            row = conn.execute(
                "SELECT 1 FROM devices WHERE key_digest = %s", [_digest(public_key_der)]
            ).fetchone()
        return row is not None

    def add(self, grant: EnrollmentGrant, public_key_der: bytes) -> Device | None:
        query = sql.SQL(
            "INSERT INTO devices (id, org_id, user_id, label, public_key_der, key_digest, status,"
            " enrolled_at) VALUES (%s, %s, %s, %s, %s, %s, 'pending', %s)"
            " ON CONFLICT (key_digest) DO NOTHING RETURNING {}"
        ).format(sql.SQL(COLUMNS))
        params = [uuid.uuid4(), grant.org_id, grant.user_id, grant.device_label, public_key_der]
        return self._one(query, [*params, _digest(public_key_der), self._clock()])

    def update(self, device: Device, **changes: object) -> Device:
        unknown = set(changes) - UPDATABLE
        if unknown:
            raise ValueError(f"cannot change {sorted(unknown)}")
        assignments = sql.SQL(", ").join(
            sql.SQL("{} = %s").format(sql.Identifier(name)) for name in changes
        )
        query = sql.SQL("UPDATE devices SET {} WHERE id = %s RETURNING {}").format(
            assignments, sql.SQL(COLUMNS)
        )
        updated = self._one(query, [*changes.values(), uuid.UUID(device.id)])
        if updated is None:
            raise LookupError(f"device {device.id} is gone")
        return updated

    def accept_seq(self, device_id: str, seq: int) -> bool:
        with self._pool.connection() as conn:
            row = conn.execute(
                "UPDATE devices SET last_seq = %s WHERE id = %s AND last_seq < %s RETURNING id",
                [seq, _uuid(device_id), seq],
            ).fetchone()
        return row is not None


class Directory:
    MIGRATIONS = MIGRATIONS

    def __init__(self, pool: ConnectionPool, clock: Callable[[], float]):
        self._pool = pool
        self.codes = PostgresEnrollmentCodes(pool, clock)
        self.devices = PostgresDeviceRegistry(pool, clock)
        self.audit = PostgresAuditLog(pool, clock)

    @classmethod
    @contextmanager
    def open(
        cls, url: str, clock: Callable[[], float] = time.time, migrations: bool = True
    ) -> Generator["Directory"]:
        """Pooled connections to the directory; first brings its tables up to date, unless told not
        to (the server never migrates at start: it checks, and an operator migrates)."""
        if migrations:
            migrate(url, load(MIGRATIONS))
        with open_pool(url) as pool:
            yield cls(pool, clock)

    def ready(self) -> bool:
        """Whether the directory answers a trivial query within 2 s (#103 step 4.5): a quick no,
        never a hang, so /v1/ready can say 503 while Postgres is down or starting."""
        try:
            with self._pool.connection(timeout=READY_TIMEOUT_SECONDS) as conn:
                conn.execute("SELECT 1")
        except psycopg.Error:  # includes the pool's PoolTimeout (an OperationalError)
            return False
        return True

    def organizations(self) -> dict[str, str]:
        """Every organization and the name of its database."""
        with self._pool.connection() as conn:
            return dict(conn.execute("SELECT id, database FROM organizations").fetchall())

    def add_organization(self, org_id: str, database: str) -> None:
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO organizations (id, database) VALUES (%s, %s)", [org_id, database]
            )
