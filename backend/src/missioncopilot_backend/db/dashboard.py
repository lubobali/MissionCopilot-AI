"""The dashboard's people and sign-in in the directory database (#174, step 8.4.1). Same contract as
DashboardMemory (tests/db/test_dashboard_store.py runs both). One-time use is closed by Postgres
itself: a code or challenge is deleted as it is read (DELETE ... RETURNING), and a sign count is
raised only if it counts up (one UPDATE), so two copies of a request cannot both pass."""

import secrets
import uuid
from collections.abc import Callable

from psycopg_pool import ConnectionPool

from missioncopilot_backend.dashboard_auth import (
    CHALLENGE_SECONDS,
    INVITE_SECONDS,
    SESSION_SECONDS,
    Challenge,
    DashboardUser,
    Passkey,
    Purpose,
    digest,
)

USER = "SELECT id, org_id, user_id, name, roles FROM dashboard_users"


def _user(row: tuple) -> DashboardUser:
    found, org_id, user_id, name, roles = row
    return DashboardUser(str(found), org_id, user_id, name, tuple(roles))


def _uuid(text: str | None) -> uuid.UUID | None:
    try:
        return uuid.UUID(text) if text else None
    except ValueError:
        return None


class PostgresDashboard:
    def __init__(self, pool: ConnectionPool, clock: Callable[[], float]):
        self._pool, self._clock = pool, clock

    def add_user(
        self, org_id: str, user_id: str, name: str, roles: tuple[str, ...]
    ) -> DashboardUser:
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO dashboard_users VALUES (%s, %s, %s, %s, %s, %s)"
                " ON CONFLICT (org_id, user_id) DO NOTHING",
                [uuid.uuid4(), org_id, user_id, name, list(roles), self._clock()],
            )
            row = conn.execute(
                USER + " WHERE org_id = %s AND user_id = %s", [org_id, user_id]
            ).fetchone()
        if row is None:  # inserted or already there, so never missing
            raise LookupError(f"dashboard user {org_id}/{user_id} is gone")
        return _user(row)

    def user(self, dashboard_user_id: str) -> DashboardUser | None:
        key = _uuid(dashboard_user_id)
        if key is None:
            return None
        with self._pool.connection() as conn:
            row = conn.execute(USER + " WHERE id = %s", [key]).fetchone()
        return _user(row) if row else None

    def issue_invite(self, dashboard_user_id: str) -> tuple[str, float]:
        code, expires = secrets.token_urlsafe(16), self._clock() + INVITE_SECONDS
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO dashboard_invites VALUES (%s, %s, %s)",
                [digest(code), uuid.UUID(dashboard_user_id), expires],
            )
        return code, expires

    def consume_invite(self, code: str) -> DashboardUser | None:
        with self._pool.connection() as conn:
            row = conn.execute(
                "DELETE FROM dashboard_invites WHERE digest = %s RETURNING user_ref, expires_at",
                [digest(code)],
            ).fetchone()
        if row is None or self._clock() >= row[1]:
            return None
        return self.user(str(row[0]))

    def new_challenge(
        self, purpose: Purpose, dashboard_user_id: str | None, subject: str | None = None
    ) -> bytes:
        challenge = secrets.token_bytes(32)
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO webauthn_challenges (digest, purpose, user_ref, expires_at, subject)"
                " VALUES (%s, %s, %s, %s, %s)",
                [digest(challenge), purpose, _uuid(dashboard_user_id),
                 self._clock() + CHALLENGE_SECONDS, subject],
            )  # fmt: skip
        return challenge

    def take_challenge(self, challenge: bytes, purpose: Purpose) -> Challenge | None:
        with self._pool.connection() as conn:
            row = conn.execute(
                "DELETE FROM webauthn_challenges WHERE digest = %s"
                " RETURNING purpose, user_ref, expires_at, subject",
                [digest(challenge)],
            ).fetchone()
        if row is None or self._clock() >= row[2] or row[0] != purpose:
            return None
        return Challenge(row[0], str(row[1]) if row[1] else None, row[3])

    def add_passkey(
        self, dashboard_user_id: str, credential_id: bytes, public_key: bytes, sign_count: int
    ) -> None:
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO passkeys VALUES (%s, %s, %s, %s, %s)",
                [credential_id, uuid.UUID(dashboard_user_id), public_key, sign_count,
                 self._clock()],
            )  # fmt: skip

    def passkey(self, credential_id: bytes) -> Passkey | None:
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT credential_id, user_ref, public_key, sign_count FROM passkeys"
                " WHERE credential_id = %s",
                [credential_id],
            ).fetchall()
        found = [Passkey(bytes(c), str(u), bytes(k), n) for c, u, k, n in rows]
        return found[0] if found else None

    def passkeys_of(self, dashboard_user_id: str) -> list[Passkey]:
        key = _uuid(dashboard_user_id)
        if key is None:
            return []
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT credential_id, user_ref, public_key, sign_count FROM passkeys"
                " WHERE user_ref = %s ORDER BY added_at",
                [key],
            ).fetchall()
        return [Passkey(bytes(c), str(u), bytes(k), n) for c, u, k, n in rows]

    def raise_sign_count(self, credential_id: bytes, sign_count: int) -> bool:
        with self._pool.connection() as conn:
            row = conn.execute(
                "UPDATE passkeys SET sign_count = %s WHERE credential_id = %s"
                " AND ((sign_count = 0 AND %s = 0) OR %s > sign_count) RETURNING 1",
                [sign_count, credential_id, sign_count, sign_count],
            ).fetchone()
        return row is not None

    def new_session(self, dashboard_user_id: str) -> str:
        token = secrets.token_urlsafe(32)
        with self._pool.connection() as conn:
            conn.execute(
                "INSERT INTO dashboard_sessions VALUES (%s, %s, %s)",
                [digest(token), uuid.UUID(dashboard_user_id), self._clock() + SESSION_SECONDS],
            )
        return token

    def session(self, token: str) -> DashboardUser | None:
        with self._pool.connection() as conn:
            row = conn.execute(
                "SELECT user_ref, expires_at FROM dashboard_sessions WHERE digest = %s",
                [digest(token)],
            ).fetchone()
        if row is None or self._clock() >= row[1]:
            return None
        return self.user(str(row[0]))

    def end_session(self, token: str) -> None:
        with self._pool.connection() as conn:
            conn.execute("DELETE FROM dashboard_sessions WHERE digest = %s", [digest(token)])
