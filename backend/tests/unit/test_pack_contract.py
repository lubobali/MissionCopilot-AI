"""The mission pack in the API contract (#89, threat T51): a signed manifest that lists every file
by its SHA-256 and size, a detached signature, and each file served so a phone can resume after a
lost signal. Example manifests are checked against the contract's own schema, so the limits are
real."""

import copy
import json
from pathlib import Path
from typing import Any

import pytest
import yaml
from jsonschema import Draft202012Validator
from jsonschema.protocols import Validator

pytestmark = pytest.mark.unit

SPEC_PATH = Path(__file__).resolve().parents[3] / "docs" / "api" / "openapi.yaml"
SPEC = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))
BASE = "/v1/missions/{missionId}/pack"
PACK_OPERATIONS = {
    f"GET {BASE}/manifest": "getPackManifest",
    f"GET {BASE}/signature": "getPackSignature",
    f"GET {BASE}/files/{{sha256}}": "getPackFile",
}
# One source for the example manifests, read by these tests, the pack code's tests and the app's.
CASES = json.loads(
    (SPEC_PATH.parent / "fixtures" / "pack-manifest-cases.json").read_text(encoding="utf-8")
)
GOOD: dict[str, Any] = CASES["good"]
BAD: list[dict[str, Any]] = CASES["bad"]


def _validator(name: str) -> Validator:
    root = dict(SPEC) | {"$ref": f"#/components/schemas/{name}"}  # resolves the contract's own refs
    return Draft202012Validator(root)


def _operations():
    for path, item in SPEC["paths"].items():
        for method, op in item.items():
            yield f"{method.upper()} {path}", op


def test_the_three_pack_operations_exist():
    found = {name: op["operationId"] for name, op in _operations()}

    assert {name: found.get(name) for name in PACK_OPERATIONS} == PACK_OPERATIONS
    assert "getMissionPack" not in found.values()  # the old unsigned pack is gone


@pytest.mark.parametrize("name", PACK_OPERATIONS)
def test_only_an_enrolled_phone_may_download_a_pack(name):
    op = dict(_operations())[name]

    assert op["security"] == [{"deviceSignature": []}]
    assert {"401", "404", "410", "429"} <= set(op["responses"])


def test_a_good_manifest_matches_the_contract():
    assert list(_validator("MissionPack").iter_errors(GOOD)) == []


@pytest.mark.parametrize("bad", BAD)
def test_a_manifest_outside_the_limits_is_refused(bad):
    assert list(_validator("MissionPack").iter_errors(bad)) != []


@pytest.mark.parametrize("missing", sorted(GOOD))
def test_every_manifest_field_is_required(missing):
    manifest = copy.deepcopy(GOOD)
    del manifest[missing]

    assert list(_validator("MissionPack").iter_errors(manifest)) != []


def test_the_signature_names_its_key_and_algorithm():
    good = {"keyId": "0123456789abcdef", "algorithm": "ecdsa-p256-sha256", "signature": "MEUCIQ=="}

    assert list(_validator("PackSignature").iter_errors(good)) == []
    for bad in (good | {"algorithm": "rsa"}, good | {"keyId": "x"}, {"keyId": good["keyId"]}):
        assert list(_validator("PackSignature").iter_errors(bad)) != []


def test_a_file_can_be_fetched_in_parts_to_resume_a_download():
    op = dict(_operations())[f"GET {BASE}/files/{{sha256}}"]
    params = {p["name"]: p for p in op["parameters"] if "name" in p}

    assert {"Range", "If-Range"} <= set(params)
    assert params["Range"]["in"] == params["If-Range"]["in"] == "header"
    assert {"200", "206", "416"} <= set(op["responses"])
    for status in ("200", "206"):
        assert {"ETag", "Accept-Ranges", "Cache-Control"} <= set(op["responses"][status]["headers"])


def _resolve(node: dict) -> dict:
    if "$ref" not in node:
        return node
    found: dict = SPEC
    for part in node["$ref"].removeprefix("#/").split("/"):
        found = found[part]
    return found


def test_pack_answers_are_never_cached():
    for name in PACK_OPERATIONS:
        ok = dict(_operations())[name]["responses"]["200"]
        assert _resolve(ok["headers"]["Cache-Control"])["schema"]["const"] == "no-store"
