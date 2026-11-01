"""Device enrollment (threat model T26, docs/security.md). An admin issues a one-time code for one
named person's phone in the admin's organization. The code is 128 random bits, works once, expires
after 15 minutes, and only its SHA-256 hash is stored (fine for a random secret, unlike a password),
so a copy of the store reveals no live code. In memory until Postgres arrives in Phase 5."""

import dataclasses
import hashlib
import secrets
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal

from missioncopilot_backend.signatures import is_signed_by, load_p256_public_key

CODE_LIFETIME_SECONDS = 15 * 60
ENROLL_DOMAIN = b"missioncopilot-enroll-v1\n"
Status = Literal["pending", "active", "revoked"]


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


def enrollment_message(code: str, public_key_der: bytes) -> bytes:
    """The exact bytes the phone signs to enroll. The domain label keeps this signature from being
    reused anywhere else; the code and the key bind it to this one enrollment."""
    return ENROLL_DOMAIN + code.encode() + b"\n" + public_key_der


@dataclass(frozen=True)
class Device:
    id: str
    org_id: str
    user_id: str
    label: str
    public_key_der: bytes
    status: Status
    enrolled_at: float
    last_seq: int = 0  # the highest signed request sequence number accepted (46.5)


class DeviceRegistry:
    """Enrolled phones. A device id is a random UUID; routes check the caller's organization."""

    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._devices: dict[str, Device] = {}
        self._keys: set[str] = set()  # SHA-256 of every enrolled public key

    def find(self, device_id: str) -> Device | None:
        return self._devices.get(device_id)

    def has_key(self, public_key_der: bytes) -> bool:
        return hashlib.sha256(public_key_der).hexdigest() in self._keys

    def add(self, grant: EnrollmentGrant, public_key_der: bytes) -> Device:
        device = Device(
            id=str(uuid.uuid4()),
            org_id=grant.org_id,
            user_id=grant.user_id,
            label=grant.device_label,
            public_key_der=public_key_der,
            status="pending",
            enrolled_at=self._clock(),
        )
        self._devices[device.id] = device
        self._keys.add(hashlib.sha256(public_key_der).hexdigest())
        return device

    def update(self, device: Device, **changes: object) -> Device:
        updated = dataclasses.replace(device, **changes)
        self._devices[device.id] = updated
        return updated


def enroll(
    codes: EnrollmentCodes, devices: DeviceRegistry, code: str, public_key_der: bytes, proof: bytes
) -> Device | None:
    """A pending device, or None. The key and proof are checked before the code is used, so a
    failed proof does not burn it. A thief with a code can still make their own key: a manager's
    approval is what stops that."""
    key = load_p256_public_key(public_key_der)
    if key is None or not is_signed_by(key, proof, enrollment_message(code, public_key_der)):
        return None
    if devices.has_key(public_key_der):
        return None
    grant = codes.consume(code)
    return devices.add(grant, public_key_der) if grant else None
