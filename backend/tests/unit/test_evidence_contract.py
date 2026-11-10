"""Signed evidence, payload v2 (ADR 0009, #71). The contract says exactly which bytes the phone
signs, so the server can check them without rebuilding anything: kind, clock source and location
are now inside the signature. The written format, docs/evidence-format.md, agrees with it."""

import base64
import json
import re
from pathlib import Path

import jsonschema
import pytest
import yaml

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
SPEC = yaml.safe_load((ROOT / "docs" / "api" / "openapi.yaml").read_text(encoding="utf-8"))
SCHEMAS = SPEC["components"]["schemas"]
FORMAT_DOC = (ROOT / "docs" / "evidence-format.md").read_text(encoding="utf-8")
SIGNED = {"v", "seq", "prevHash", "contentHash", "kind", "capturedAt", "clockSource", "missionId"}


def example_payload() -> dict:
    """The example in docs/evidence-format.md (the one json block)."""
    block = re.search(r"```json\n(.*?)\n```", FORMAT_DOC, re.S)
    assert block, "docs/evidence-format.md needs one json example"
    return json.loads(block.group(1))


def test_the_payload_has_exactly_the_signed_fields():
    payload = SCHEMAS["EvidencePayload"]

    assert payload["additionalProperties"] is False
    assert set(payload["required"]) == SIGNED
    assert set(payload["properties"]) == SIGNED | {"location"}


def test_each_signed_field_is_strict():
    fields = SCHEMAS["EvidencePayload"]["properties"]

    assert fields["v"]["const"] == 2
    assert fields["seq"] == {"type": "integer", "minimum": 1}
    assert fields["prevHash"]["pattern"] == fields["contentHash"]["pattern"] == "^[0-9a-f]{64}$"
    assert fields["kind"]["enum"] == ["photo", "scan", "audio", "pack", "walk"]
    assert fields["clockSource"]["enum"] == ["device", "gnss"]
    assert fields["capturedAt"]["pattern"] == r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"


def test_location_is_whole_micro_degrees_within_range():
    location = SCHEMAS["EvidencePayload"]["properties"]["location"]

    assert location["additionalProperties"] is False
    assert set(location["required"]) == {"latE6", "lonE6"}
    assert location["properties"]["latE6"] == {
        "type": "integer",
        "minimum": -90_000_000,
        "maximum": 90_000_000,
    }
    assert location["properties"]["lonE6"] == {
        "type": "integer",
        "minimum": -180_000_000,
        "maximum": 180_000_000,
    }


def test_evidence_is_the_signed_record_and_nothing_outside_it():
    # A second, unsigned copy of kind or time next to the signature could disagree with it.
    evidence = SCHEMAS["Evidence"]["allOf"][1]

    assert set(evidence["required"]) == {"payload", "signature"}
    assert set(evidence["properties"]) == {"payload", "signature"}
    assert evidence["properties"]["payload"]["contentEncoding"] == "base64"
    assert evidence["properties"]["signature"]["contentEncoding"] == "base64"


def test_the_chain_head_travels_with_the_evidence():
    head = SCHEMAS["ChainHead"]
    head_payload = SCHEMAS["ChainHeadPayload"]
    batch = SCHEMAS["SyncBatch"]["properties"]  # the batch as built (#172)

    assert set(head["required"]) == {"payload", "signature"}
    assert set(head_payload["required"]) == {"count", "headHash", "missionId"}
    assert batch["head"] == {"$ref": "#/components/schemas/ChainHead"}
    assert batch["evidence"]["items"] == {"$ref": "#/components/schemas/Evidence"}


def test_the_documented_example_is_a_valid_v2_payload():
    jsonschema.validate(example_payload(), SCHEMAS["EvidencePayload"])


def test_the_phones_v1_payload_is_not_v2():
    phone = json.loads(
        (ROOT / "docs/spikes/results/evidence-chain-iphone13promax.json").read_text()
    )
    v1 = json.loads(base64.b64decode(phone["records"][0]["payload"]))

    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(v1, SCHEMAS["EvidencePayload"])


def test_the_written_format_lists_the_same_fields_as_the_contract():
    documented = set(re.findall(r"^\| `(\w+)` \|", FORMAT_DOC, re.M))

    assert documented == SIGNED | {"location"}
