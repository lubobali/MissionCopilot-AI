"""Mission packs in the organization's own database (#89): an operator publishes, the mission's
team reads. The rules live in Postgres (sql/organization/0002_packs.sql): forced row-level security
by team, append-only, versions up by one, each file checked against its SHA-256."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import psycopg
from cryptography.hazmat.primitives.asymmetric import ec
from psycopg_pool import ConnectionPool

from missioncopilot_backend.db.missions import as_user
from missioncopilot_backend.pack_format import build_manifest, key_id, sign_manifest


@dataclass(frozen=True)
class Pack:
    version: int
    manifest: bytes  # exactly the bytes that were signed
    signature: dict[str, str]


def publish_pack(
    admin_url: str,
    org_id: str,
    mission_id: str,
    files: dict[str, bytes],
    key: ec.EllipticCurvePrivateKey,
    *,
    created_at: datetime | None = None,
    valid_for: timedelta = timedelta(days=30),
    min_app_version: str = "0.5",
) -> Pack:
    """The mission's next pack, built, signed and stored in one transaction. As the admin: the app
    login cannot publish. Two operators publishing at once take turns on the mission's row."""
    with psycopg.connect(admin_url) as conn, conn.transaction():
        found = conn.execute(
            "SELECT 1 FROM missions WHERE id = %s FOR UPDATE", [mission_id]
        ).fetchone()
        if found is None:
            raise ValueError(f"no mission {mission_id} in this organization")
        last = conn.execute(
            "SELECT coalesce(max(version), 0) FROM packs WHERE mission_id = %s", [mission_id]
        ).fetchone()
        version = (last[0] if last else 0) + 1
        manifest = build_manifest(
            org_id=org_id,
            mission_id=mission_id,
            version=version,
            files=files,
            created_at=created_at or datetime.now(UTC),
            valid_for=valid_for,
            min_app_version=min_app_version,
            key_id=key_id(key.public_key()),
        )
        signature = sign_manifest(manifest, key)
        entries = json.loads(manifest)
        for entry in entries["files"]:
            conn.execute(
                "INSERT INTO pack_files (sha256, data) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                [entry["sha256"], files[entry["path"]]],
            )
        conn.execute(
            "INSERT INTO packs (mission_id, version, pack_id, manifest, signature, key_id,"
            " created_at, expires_at) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
            [
                mission_id, version, entries["packId"], manifest, json.dumps(signature),
                signature["keyId"], entries["createdAt"], entries["expiresAt"],
            ],
        )  # fmt: skip
        for entry in entries["files"]:
            conn.execute(
                "INSERT INTO pack_contents (mission_id, version, path, sha256)"
                " VALUES (%s, %s, %s, %s)",
                [mission_id, version, entry["path"], entry["sha256"]],
            )
    return Pack(version, manifest, signature)


class PostgresPacks:
    """Reading packs as one user; Postgres decides what that user may see."""

    def __init__(self, pool: ConnectionPool):
        self._pool = pool

    def newest(self, user_id: str, mission_id: str) -> Pack | None:
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT version, manifest, signature FROM packs WHERE mission_id = %s"
                " ORDER BY version DESC LIMIT 1",
                [mission_id],
            ).fetchone()
        return Pack(row[0], bytes(row[1]), row[2]) if row else None

    def file(self, user_id: str, mission_id: str, sha256: str) -> bytes | None:
        """A file of any of this mission's packs the user may read, so a download started on an
        older version can still finish."""
        with as_user(self._pool, user_id) as conn:
            row = conn.execute(
                "SELECT f.data FROM pack_files f WHERE f.sha256 = %s AND EXISTS ("
                " SELECT 1 FROM pack_contents c WHERE c.sha256 = f.sha256 AND c.mission_id = %s)",
                [sha256, mission_id],
            ).fetchone()
        return bytes(row[0]) if row else None
