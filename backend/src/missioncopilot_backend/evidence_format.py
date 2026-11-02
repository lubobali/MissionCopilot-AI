"""The signed evidence payload format (docs/evidence-format.md). The signature proves who signed an
item; these rules prove the item also follows the format, so a buggy or hostile phone cannot slip a
bad field in. Same rules as EvidencePayload in the API contract.
"""

import re

V1_FIELDS = {"capturedAt", "fileSHA256", "missionId", "prevHash", "seq"}
V2_REQUIRED = {
    "v",
    "seq",
    "prevHash",
    "contentHash",
    "kind",
    "capturedAt",
    "clockSource",
    "missionId",
}
HEX64 = re.compile(r"[0-9a-f]{64}")
TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
KINDS = {"photo", "scan", "audio"}
CLOCKS = {"device", "gnss"}


def _integer(value: object, low: int, high: int) -> bool:
    # bool is an int in Python: JSON true must not pass as a number.
    return type(value) is int and low <= value <= high


def _location_ok(location: object) -> bool:
    return (
        isinstance(location, dict)
        and set(location) == {"latE6", "lonE6"}
        and _integer(location["latE6"], -90_000_000, 90_000_000)
        and _integer(location["lonE6"], -180_000_000, 180_000_000)
    )


def version(payload: dict) -> int | None:
    """2 for a valid v2 payload, 1 for the spike's v1 shape, None if it follows neither."""
    if "v" not in payload:
        return 1 if set(payload) == V1_FIELDS else None
    keys = set(payload)
    valid = (
        payload["v"] == 2
        and type(payload["v"]) is int
        and V2_REQUIRED <= keys <= V2_REQUIRED | {"location"}
        and _integer(payload["seq"], 1, 2**63)
        and all(
            isinstance(payload[f], str) and HEX64.fullmatch(payload[f])
            for f in ("prevHash", "contentHash")
        )
        and payload["kind"] in KINDS
        and payload["clockSource"] in CLOCKS
        and isinstance(payload["capturedAt"], str)
        and TIME.fullmatch(payload["capturedAt"]) is not None
        and isinstance(payload["missionId"], str)
        and ("location" not in payload or _location_ok(payload["location"]))
    )
    return 2 if valid else None
