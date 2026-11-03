"""Shared pieces for the pack format tests (#89): a signing key, a small fictional pack, and a
helper that returns the reason a pack was refused."""

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.pack_format import PackError, build_manifest, key_id

NOW = datetime(2026, 11, 3, 12, 0, tzinfo=UTC)
MISSION = "6f1d2c3a-0000-4000-8000-000000000001"
PACK = "0b6f0a52-6a0b-4c55-9d0e-3f1a2b3c4d5e"
FILES = {
    "sections/project.json": b'{"title": "Kandor Rural Roads Project, Package 1"}',
    "forms/road-checklist.json": b'{"survey": []}',
    "documents/aide-memoire.md": b"# Aide-memoire\n",
}


@pytest.fixture(scope="module")
def key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def _manifest(key, files=None, **overrides) -> bytes:
    args: dict[str, Any] = {
        "org_id": "kandor-works",
        "mission_id": MISSION,
        "version": 3,
        "files": FILES if files is None else files,
        "created_at": NOW,
        "valid_for": timedelta(days=30),
        "min_app_version": "0.5",
        "key_id": key_id(key.public_key()),
        "pack_id": PACK,
    } | overrides
    return build_manifest(**args)


def _keys(key) -> dict:
    return {key_id(key.public_key()): key.public_key()}


def _reason(call) -> str:
    with pytest.raises(PackError) as error:
        call()
    return error.value.reason
