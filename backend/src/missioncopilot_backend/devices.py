"""Device enrollment (threat model T26, docs/security.md). An admin issues a one-time code for one
named person's phone in the admin's organization. The code is 128 random bits, works once, expires
after 15 minutes, and only its SHA-256 hash is stored (fine for a random secret, unlike a password),
so a copy of the store reveals no live code. In memory until Postgres arrives in Phase 5."""

import hashlib
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass

CODE_LIFETIME_SECONDS = 15 * 60


@dataclass(frozen=True)
class EnrollmentGrant:
    """What a valid code allows: enroll one phone for this person in this organization."""

    org_id: str
    user_id: str
    device_label: str
    expires_at: float


def _digest(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


class EnrollmentCodes:
    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._grants: dict[str, EnrollmentGrant] = {}  # by SHA-256 of the code

    def issue(self, org_id: str, user_id: str, device_label: str) -> tuple[str, EnrollmentGrant]:
        code = secrets.token_urlsafe(16)
        grant = EnrollmentGrant(
            org_id, user_id, device_label, self._clock() + CODE_LIFETIME_SECONDS
        )
        self._grants[_digest(code)] = grant
        return code, grant

    def consume(self, code: str) -> EnrollmentGrant | None:
        """The grant, once: the code is removed as it is used. Unknown or expired: None."""
        grant = self._grants.pop(_digest(code), None)
        if grant is None or self._clock() >= grant.expires_at:
            return None
        return grant
