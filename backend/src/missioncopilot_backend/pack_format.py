"""The mission pack format (API contract MissionPack, threat T51, #89).

The server builds one manifest per pack: every file by path, SHA-256, size and media type, plus the
pack's version, expiry, minimum app version and the id of the signing key. The bytes are canonical
(sorted keys, no spaces) so the same pack gives the same bytes. The signature is ECDSA P-256 over a
domain label and those exact bytes, so it can never pass as a shred order, and the phone checks the
bytes it received without ever re-encoding them.

verify_pack and check_file are the phone's checks written in Python: tests and fixtures use them,
and the Swift code (#91) must agree. A signature proves who wrote a manifest, not that it is safe,
so the rules are checked after it too."""

import base64
import binascii
import hashlib
import json
import re
import uuid
from datetime import UTC, datetime, timedelta

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from missioncopilot_backend.signatures import is_signed_by

PACK_DOMAIN = b"missioncopilot-pack-v1\n"
ALGORITHM = "ecdsa-p256-sha256"
FORMAT, FORMAT_VERSION = "missioncopilot-pack", 2
MAX_FILES = 64
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_PACK_BYTES = 50 * 1024 * 1024
MEDIA_TYPES = {
    "json": "application/json",
    "md": "text/markdown",
    "pdf": "application/pdf",
    "jpg": "image/jpeg",
}
PATH = re.compile(r"^(sections|forms|documents)/[a-z0-9][a-z0-9-]{0,62}\.(json|md|pdf|jpg)$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ORG = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
APP_VERSION = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
KEY_ID = re.compile(r"^[0-9a-f]{16}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
TIME = "%Y-%m-%dT%H:%M:%SZ"
MANIFEST_KEYS = {
    "format", "formatVersion", "packId", "orgId", "missionId", "version", "createdAt",
    "expiresAt", "minAppVersion", "keyId", "files",
}  # fmt: skip
FILE_KEYS = {"path", "sha256", "size", "mediaType"}


class PackError(ValueError):
    """A pack that must not be built or used; reason is a short code tests and logs can rely on."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def key_id(public_key: ec.EllipticCurvePublicKey) -> str:
    der = public_key.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return hashlib.sha256(der).hexdigest()[:16]


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _require(ok: bool, reason: str) -> None:
    if not ok:
        raise PackError(reason)


def _files(files: dict[str, bytes]) -> list[dict]:
    _require(bool(files), "no_files")
    _require(len(files) <= MAX_FILES, "too_many_files")
    entries = []
    for path, data in sorted(files.items()):
        _require(bool(PATH.match(path)), "bad_path")
        _require(len(data) <= MAX_FILE_BYTES, "file_too_large")
        media_type = MEDIA_TYPES[path.rsplit(".", 1)[1]]
        sha = hashlib.sha256(data).hexdigest()
        entries.append({"path": path, "sha256": sha, "size": len(data), "mediaType": media_type})
    _require(sum(len(data) for data in files.values()) <= MAX_PACK_BYTES, "pack_too_large")
    return entries


def build_manifest(
    *,
    org_id: str,
    mission_id: str,
    version: int,
    files: dict[str, bytes],
    created_at: datetime,
    valid_for: timedelta,
    min_app_version: str,
    key_id: str,
    pack_id: str | None = None,
) -> bytes:
    """The canonical manifest bytes for these files; refuses a pack outside the limits."""
    _require(bool(ORG.match(org_id)), "bad_org")
    _require(bool(UUID.match(mission_id)), "bad_mission")
    _require(isinstance(version, int) and not isinstance(version, bool) and version >= 1,
             "bad_version")  # fmt: skip
    _require(valid_for > timedelta(0), "bad_expiry")
    _require(bool(APP_VERSION.match(min_app_version)), "bad_app_version")
    _require(bool(KEY_ID.match(key_id)), "bad_key")
    created = created_at.astimezone(UTC)
    manifest = {
        "format": FORMAT,
        "formatVersion": FORMAT_VERSION,
        "packId": pack_id or str(uuid.uuid4()),
        "orgId": org_id,
        "missionId": mission_id,
        "version": version,
        "createdAt": created.strftime(TIME),
        "expiresAt": (created + valid_for).strftime(TIME),
        "minAppVersion": min_app_version,
        "keyId": key_id,
        "files": _files(files),
    }
    return _canonical(check_manifest(manifest))


def sign_manifest(manifest: bytes, key: ec.EllipticCurvePrivateKey) -> dict[str, str]:
    signature = key.sign(PACK_DOMAIN + manifest, ec.ECDSA(hashes.SHA256()))
    return {
        "keyId": key_id(key.public_key()),
        "algorithm": ALGORITHM,
        "signature": base64.b64encode(signature).decode(),
    }


def _int(value: object, low: int, high: int | None = None) -> bool:
    if not isinstance(value, int) or isinstance(value, bool):
        return False
    return value >= low and (high is None or value <= high)


def _time(value: object) -> bool:
    try:
        return isinstance(value, str) and datetime.strptime(value, TIME) is not None
    except ValueError:
        return False


def _text(value: object, pattern: re.Pattern[str]) -> bool:
    return isinstance(value, str) and bool(pattern.match(value))


def _file_ok(entry: object) -> bool:
    return (
        isinstance(entry, dict)
        and set(entry) == FILE_KEYS
        and _text(entry["path"], PATH)
        and _text(entry["sha256"], SHA256)
        and _int(entry["size"], 0, MAX_FILE_BYTES)
        and entry["mediaType"] in MEDIA_TYPES.values()
    )


def _rules_ok(manifest: dict) -> bool:
    files = manifest["files"]
    return (
        set(manifest) == MANIFEST_KEYS
        and manifest["format"] == FORMAT
        and _int(manifest["formatVersion"], FORMAT_VERSION, FORMAT_VERSION)
        and _text(manifest["packId"], UUID)
        and _text(manifest["orgId"], ORG)
        and _text(manifest["missionId"], UUID)
        and _int(manifest["version"], 1)
        and _time(manifest["createdAt"])
        and _time(manifest["expiresAt"])
        and _text(manifest["minAppVersion"], APP_VERSION)
        and _text(manifest["keyId"], KEY_ID)
        and isinstance(files, list)
        and 1 <= len(files) <= MAX_FILES
        and all(_file_ok(entry) for entry in files)
        and sum(entry["size"] for entry in files) <= MAX_PACK_BYTES
    )


def check_manifest(manifest: object) -> dict:
    """The manifest if it keeps every rule of the API contract; otherwise PackError("malformed")."""
    if not isinstance(manifest, dict) or not set(manifest) >= MANIFEST_KEYS:
        raise PackError("malformed")
    if not _rules_ok(manifest):
        raise PackError("malformed")
    return manifest


def verify_pack(
    manifest: bytes,
    signature: dict[str, str],
    keys: dict[str, ec.EllipticCurvePublicKey],
    now: datetime,
) -> dict:
    """The manifest as data, only if a pinned key signed these exact bytes, it keeps the rules, it
    names the key that signed it, and it has not expired."""
    key = keys.get(signature.get("keyId", ""))
    if key is None:
        raise PackError("unknown_key")
    _require(signature.get("algorithm") == ALGORITHM, "bad_signature")
    try:
        raw = base64.b64decode(signature.get("signature", ""), validate=True)
    except (binascii.Error, ValueError):
        raise PackError("bad_signature") from None
    _require(bool(raw) and is_signed_by(key, raw, PACK_DOMAIN + manifest), "bad_signature")
    try:
        data = check_manifest(json.loads(manifest))
    except ValueError:  # not JSON, not UTF-8, or a broken rule
        raise PackError("malformed") from None
    _require(data["keyId"] == signature["keyId"], "key_mismatch")
    expires = datetime.strptime(data["expiresAt"], TIME).replace(tzinfo=UTC)
    _require(now < expires, "expired")
    return data


def check_file(entry: dict, data: bytes) -> None:
    """A downloaded file must be exactly what its manifest entry says."""
    _require(len(data) == entry["size"], "wrong_size")
    _require(hashlib.sha256(data).hexdigest() == entry["sha256"], "wrong_hash")
