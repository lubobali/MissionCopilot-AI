"""A real server for phone routes (#89, #92): a throwaway directory, two organizations with their
own databases (ROADS for officer-7, BRIDGES for officer-8; the same mission ids in both), one roads
pack published in the first, and enrolled phones with real P-256 keys that sign every request."""

import base64
import json
import uuid
from collections.abc import Generator
from dataclasses import dataclass
from datetime import UTC, datetime

import psycopg
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo
from psycopg_pool import ConnectionPool

from missioncopilot_backend.app import create_app
from missioncopilot_backend.approval_keys import ApprovalKeyStore
from missioncopilot_backend.db.directory import Directory
from missioncopilot_backend.db.migrations import load
from missioncopilot_backend.db.missions import ORG_MIGRATIONS, PostgresOrgDatabases
from missioncopilot_backend.db.organizations import drop_organization, provision
from missioncopilot_backend.db.packs import publish_pack
from missioncopilot_backend.device_auth import request_message
from missioncopilot_backend.devices import EnrollmentGrant
from missioncopilot_backend.settings import Settings
from tests.db.postgres import admin_url, throwaway_database
from tests.unit.clients import local_client

ROADS = "6f1d2c3a-0000-4000-8000-000000000001"
BRIDGES = "6f1d2c3a-0000-4000-8000-000000000002"
DOCUMENT = b"# Aide-memoire\n" + b"0123456789" * 10  # 115 bytes, enough to ask for parts
FILES = {"sections/project.json": b'{"title": "Kandor roads"}\n', "documents/memo.md": DOCUMENT}


class Clock:
    def __init__(self) -> None:
        self.now = datetime.now(UTC).timestamp()

    def __call__(self) -> float:
        return self.now


@dataclass
class Phone:
    id: str
    key: ec.EllipticCurvePrivateKey
    seq: int = 0

    def headers(
        self, path: str, at: float, method: str = "GET", body: bytes = b""
    ) -> dict[str, str]:
        self.seq += 1
        message = request_message(method, path, self.id, self.seq, int(at), body)
        signature = self.key.sign(message, ec.ECDSA(hashes.SHA256()))
        return {
            "X-Device-Id": self.id,
            "X-Device-Seq": str(self.seq),
            "X-Device-Time": str(int(at)),
            "X-Device-Signature": base64.b64encode(signature).decode(),
        }


@dataclass
class World:
    client: TestClient
    clock: Clock
    directory_url: str
    signing_key: ec.EllipticCurvePrivateKey
    phones: dict[str, Phone]
    manifest: bytes
    orgs: list[str]
    approval_keys: ApprovalKeyStore

    def get(self, who: str, path: str, **headers: str):
        signed = self.phones[who].headers(path, self.clock.now)
        return self.client.get(path, headers=signed | headers)

    def post(self, who: str, path: str, body: bytes, headers: dict[str, str] | None = None):
        signed = self.phones[who].headers(path, self.clock.now, "POST", body)
        sent = signed | {"Content-Type": "application/json"} | (headers or {})
        return self.client.post(path, content=body, headers=sent)

    def file_path(self, path: str, mission: str = ROADS) -> str:
        sha = next(e["sha256"] for e in json.loads(self.manifest)["files"] if e["path"] == path)
        return f"/v1/missions/{mission}/pack/files/{sha}"


def _org(directory: Directory, org_id: str) -> tuple[str, str]:
    created = provision(admin_url(), org_id, load(ORG_MIGRATIONS))
    directory.add_organization(org_id, created.database)
    admin = make_conninfo(admin_url(), dbname=created.database)
    with psycopg.connect(admin) as conn:
        conn.execute(
            "INSERT INTO missions (id, title) VALUES (%s, 'Roads'), (%s, 'Bridges')",
            [ROADS, BRIDGES],
        )
        conn.execute(
            "INSERT INTO mission_members VALUES (%s, 'officer-7'), (%s, 'officer-8')",
            [ROADS, BRIDGES],
        )
    app = make_conninfo(
        admin_url(), user=created.app_role, password=created.app_password, dbname=created.database
    )
    return admin, app


def _enroll(directory: Directory, org_id: str, user: str, status: str = "active") -> Phone:
    key = ec.generate_private_key(ec.SECP256R1())
    der = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    device = directory.devices.add(EnrollmentGrant(org_id, user, f"{user} phone", 0.0), der)
    assert device is not None
    return Phone(directory.devices.update(device, status=status).id, key)


@pytest.fixture
def world() -> Generator[World]:
    orgs = [f"t-{uuid.uuid4().hex[:12]}" for _ in range(2)]
    clock, signing_key = Clock(), ec.generate_private_key(ec.SECP256R1())
    try:
        with (
            throwaway_database() as directory_url,
            Directory.open(directory_url, clock) as directory,
        ):
            (admin_a, app_a), (_, app_b) = _org(directory, orgs[0]), _org(directory, orgs[1])
            published = publish_pack(admin_a, orgs[0], ROADS, FILES, signing_key)
            phones = {
                "officer-7": _enroll(directory, orgs[0], "officer-7"),
                "officer-8": _enroll(directory, orgs[0], "officer-8"),
                "other-org": _enroll(directory, orgs[1], "officer-7"),  # same name, other org
                "revoked": _enroll(directory, orgs[0], "officer-7", status="revoked"),
                "pending": _enroll(directory, orgs[0], "officer-7", status="pending"),
            }
            with (
                ConnectionPool(app_a, min_size=1, max_size=2, open=True) as pool_a,
                ConnectionPool(app_b, min_size=1, max_size=2, open=True) as pool_b,
            ):
                app = create_app(
                    Settings(),
                    databases=PostgresOrgDatabases({orgs[0]: pool_a, orgs[1]: pool_b}),
                    audit=directory.audit, devices=directory.devices,
                    approval_keys=directory.approval_keys, signing_key=signing_key,
                )  # fmt: skip
                yield World(local_client(app), clock, directory_url, signing_key, phones,
                            published.manifest, orgs, directory.approval_keys)  # fmt: skip
    finally:
        for org_id in orgs:
            drop_organization(admin_url(), org_id)
