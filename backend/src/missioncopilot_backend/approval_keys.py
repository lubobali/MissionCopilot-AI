"""The officer's approval keys (#171, threat T13 on the server side). Each report approval is signed
on the phone by a separate Secure Enclave key that asks Face ID every time (#163); the phone sends
that key's public key once, in a signed request, and the server keeps it with the phone. A later
sync checks an approval only against a key kept here for that phone (#172). Append-only: a new key
never erases an old one, so an old approval still checks with the key that signed it. In memory here
for tests; the server keeps them in the directory database (db/directory.py), and one contract test
runs on both (tests/db/test_approval_keys.py)."""

import hashlib
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol


def key_id(public_key_der: bytes) -> str:
    """A key's id: the SHA-256 of its SubjectPublicKeyInfo DER, in hex."""
    return hashlib.sha256(public_key_der).hexdigest()


@dataclass(frozen=True)
class ApprovalKey:
    key_id: str
    device_id: str
    public_key_der: bytes
    added_at: float


class KeyTaken(Exception):
    """The key is kept for another phone: one approval key belongs to one phone."""


class ApprovalKeyStore(Protocol):
    def add(self, device_id: str, public_key_der: bytes) -> ApprovalKey: ...
    def keys_of(self, device_id: str) -> list[ApprovalKey]: ...
    def find(self, device_id: str, key: str) -> ApprovalKey | None: ...


class ApprovalKeys:
    """In memory, for tests."""

    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._keys: dict[str, ApprovalKey] = {}  # by key id, in the order added

    def add(self, device_id: str, public_key_der: bytes) -> ApprovalKey:
        """The kept key: the same key again gives the same record; another phone's key raises
        KeyTaken."""
        found = self._keys.get(key_id(public_key_der))
        if found is not None:
            if found.device_id != device_id:
                raise KeyTaken
            return found
        key = ApprovalKey(key_id(public_key_der), device_id, public_key_der, self._clock())
        self._keys[key.key_id] = key
        return key

    def keys_of(self, device_id: str) -> list[ApprovalKey]:
        return [key for key in self._keys.values() if key.device_id == device_id]

    def find(self, device_id: str, key: str) -> ApprovalKey | None:
        found = self._keys.get(key)
        return found if found is not None and found.device_id == device_id else None
