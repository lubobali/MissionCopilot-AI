"""The dashboard's people and their sign-in (#174, step 8.4.1). A manager is invited by the operator
(a one-time code, 15 minutes), registers a passkey (Touch ID on the Mac), and signs in with it; the
server keeps a session for 8 hours. Codes, challenges and session tokens are random and work once or
until they expire; only their SHA-256 is stored, so a copy of the store reveals none of them. A
passkey's sign count only rises (a cloned authenticator is refused). In memory here for tests; the
server keeps them in the directory database (db/dashboard.py), one contract test runs on both."""

import hashlib
import secrets
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, replace
from typing import Literal, Protocol

INVITE_SECONDS = 15 * 60
CHALLENGE_SECONDS = 5 * 60
SESSION_SECONDS = 8 * 60 * 60
Purpose = Literal["register", "sign_in", "endorse"]


def digest(secret: str | bytes) -> str:
    return hashlib.sha256(secret.encode() if isinstance(secret, str) else secret).hexdigest()


@dataclass(frozen=True)
class DashboardUser:
    id: str
    org_id: str
    user_id: str
    name: str
    roles: tuple[str, ...]


@dataclass(frozen=True)
class Passkey:
    credential_id: bytes
    user_id: str  # the dashboard user's id
    public_key: bytes  # COSE
    sign_count: int


@dataclass(frozen=True)
class Challenge:
    purpose: Purpose
    user_id: str | None


class DashboardStore(Protocol):
    def add_user(
        self, org_id: str, user_id: str, name: str, roles: tuple[str, ...]
    ) -> DashboardUser: ...
    def user(self, dashboard_user_id: str) -> DashboardUser | None: ...
    def issue_invite(self, dashboard_user_id: str) -> tuple[str, float]: ...
    def consume_invite(self, code: str) -> DashboardUser | None: ...
    def new_challenge(self, purpose: Purpose, dashboard_user_id: str | None) -> bytes: ...
    def take_challenge(self, challenge: bytes, purpose: Purpose) -> Challenge | None: ...
    def add_passkey(
        self, dashboard_user_id: str, credential_id: bytes, public_key: bytes, sign_count: int
    ) -> None: ...
    def passkey(self, credential_id: bytes) -> Passkey | None: ...
    def passkeys_of(self, dashboard_user_id: str) -> list[Passkey]: ...
    def raise_sign_count(self, credential_id: bytes, sign_count: int) -> bool: ...
    def new_session(self, dashboard_user_id: str) -> str: ...
    def session(self, token: str) -> DashboardUser | None: ...
    def end_session(self, token: str) -> None: ...


def counts_up(old: int, new: int) -> bool:
    """WebAuthn: a counter of 0 then 0 means the authenticator does not count (Apple's passkeys);
    otherwise the new count must be higher, or the key may be a clone."""
    return (old == 0 and new == 0) or new > old


class DashboardMemory:
    """In memory, for tests."""

    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._users: dict[str, DashboardUser] = {}
        self._invites: dict[str, tuple[str, float]] = {}
        self._challenges: dict[str, tuple[Challenge, float]] = {}
        self._passkeys: dict[bytes, Passkey] = {}
        self._sessions: dict[str, tuple[str, float]] = {}

    def add_user(
        self, org_id: str, user_id: str, name: str, roles: tuple[str, ...]
    ) -> DashboardUser:
        found = next(
            (u for u in self._users.values() if (u.org_id, u.user_id) == (org_id, user_id)), None
        )
        if found is not None:
            return found
        user = DashboardUser(str(uuid.uuid4()), org_id, user_id, name, tuple(roles))
        self._users[user.id] = user
        return user

    def user(self, dashboard_user_id: str) -> DashboardUser | None:
        return self._users.get(dashboard_user_id)

    def issue_invite(self, dashboard_user_id: str) -> tuple[str, float]:
        code, expires = secrets.token_urlsafe(16), self._clock() + INVITE_SECONDS
        self._invites[digest(code)] = (dashboard_user_id, expires)
        return code, expires

    def consume_invite(self, code: str) -> DashboardUser | None:
        found = self._invites.pop(digest(code), None)
        if found is None or self._clock() >= found[1]:
            return None
        return self._users.get(found[0])

    def new_challenge(self, purpose: Purpose, dashboard_user_id: str | None) -> bytes:
        challenge = secrets.token_bytes(32)
        expires = self._clock() + CHALLENGE_SECONDS
        self._challenges[digest(challenge)] = (Challenge(purpose, dashboard_user_id), expires)
        return challenge

    def take_challenge(self, challenge: bytes, purpose: Purpose) -> Challenge | None:
        found = self._challenges.pop(digest(challenge), None)
        if found is None or self._clock() >= found[1] or found[0].purpose != purpose:
            return None
        return found[0]

    def add_passkey(
        self, dashboard_user_id: str, credential_id: bytes, public_key: bytes, sign_count: int
    ) -> None:
        self._passkeys[credential_id] = Passkey(
            credential_id, dashboard_user_id, public_key, sign_count
        )

    def passkey(self, credential_id: bytes) -> Passkey | None:
        return self._passkeys.get(credential_id)

    def passkeys_of(self, dashboard_user_id: str) -> list[Passkey]:
        return [p for p in self._passkeys.values() if p.user_id == dashboard_user_id]

    def raise_sign_count(self, credential_id: bytes, sign_count: int) -> bool:
        found = self._passkeys.get(credential_id)
        if found is None or not counts_up(found.sign_count, sign_count):
            return False
        self._passkeys[credential_id] = replace(found, sign_count=sign_count)
        return True

    def new_session(self, dashboard_user_id: str) -> str:
        token = secrets.token_urlsafe(32)
        self._sessions[digest(token)] = (dashboard_user_id, self._clock() + SESSION_SECONDS)
        return token

    def session(self, token: str) -> DashboardUser | None:
        found = self._sessions.get(digest(token))
        if found is None or self._clock() >= found[1]:
            return None
        return self._users.get(found[0])

    def end_session(self, token: str) -> None:
        self._sessions.pop(digest(token), None)
