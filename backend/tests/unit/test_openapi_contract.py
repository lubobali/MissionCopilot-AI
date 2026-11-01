"""The API contract (docs/api/openapi.yaml) is the single source of truth between the iPhone
app and the backend. These tests keep it valid and complete."""

from pathlib import Path

import pytest
import yaml
from openapi_spec_validator import validate

pytestmark = pytest.mark.unit

SPEC_PATH = Path(__file__).resolve().parents[3] / "docs" / "api" / "openapi.yaml"

# Domain objects that cross the network (docs/domain-model.md). KeyRef never leaves the phone.
NETWORK_OBJECTS = {
    "Mission",
    "MissionPack",
    "SourceDocument",
    "Page",
    "Evidence",
    "FieldNote",
    "RuleVersion",
    "Fact",
    "RiskFlag",
    "ReportDraft",
    "ReportSentence",
    "Approval",
    "AuditEvent",
}


@pytest.fixture(scope="module")
def spec():
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


def test_spec_is_valid_openapi(spec):
    validate(spec)


def test_every_network_object_has_a_schema(spec):
    schemas = set(spec["components"]["schemas"])

    assert NETWORK_OBJECTS - schemas == set()


def test_key_material_is_never_in_the_contract(spec):
    assert "KeyRef" not in spec["components"]["schemas"]


def test_all_paths_are_versioned(spec):
    assert all(path.startswith("/v1/") for path in spec["paths"])


def _deref(spec, node):
    while isinstance(node, dict) and "$ref" in node:
        target = spec
        for part in node["$ref"].removeprefix("#/").split("/"):
            target = target[part]
        node = target
    return node


def test_errors_use_problem_details(spec):
    assert "Problem" in spec["components"]["schemas"]
    error_responses = [
        (path, code, _deref(spec, response))
        for path, path_item in spec["paths"].items()
        for operation in path_item.values()
        for code, response in operation["responses"].items()
        if code.startswith(("4", "5"))
    ]
    assert error_responses, "expected at least one error response in the contract"
    for path, code, response in error_responses:
        assert "application/problem+json" in response["content"], f"{path} {code}"


def _operations(spec):
    return [
        (f"{method.upper()} {path}", operation)
        for path, item in spec["paths"].items()
        for method, operation in item.items()
    ]


def test_every_operation_documents_the_rate_limit(spec):
    missing = [name for name, op in _operations(spec) if "429" not in op["responses"]]

    assert missing == []
    assert (
        "Retry-After" in _deref(spec, {"$ref": "#/components/responses/TooManyRequests"})["headers"]
    )


def test_every_operation_with_a_body_documents_the_size_limit(spec):
    with_body = [(name, op) for name, op in _operations(spec) if "requestBody" in op]

    assert with_body, "expected operations with a request body"
    assert [name for name, op in with_body if "413" not in op["responses"]] == []


DEVICE_OPERATIONS = {
    "POST /v1/devices/enrollment-codes": "issueEnrollmentCode",
    "POST /v1/devices/enroll": "enrollDevice",
    "GET /v1/devices": "listDevices",
    "POST /v1/devices/{deviceId}/approve": "approveDevice",
    "POST /v1/devices/{deviceId}/revoke": "revokeDevice",
}
PHONE_OPERATIONS = {"getMissionPack", "uploadSyncBatch", "submitForReview"}
OPEN_OPERATIONS = {"getHealth", "enrollDevice"}  # enroll is authenticated by its one-time code


def test_device_enrollment_operations_exist(spec):
    found = {name: op["operationId"] for name, op in _operations(spec)}

    assert {name: found.get(name) for name in DEVICE_OPERATIONS} == DEVICE_OPERATIONS


def _security(spec, op):
    return [name for requirement in op.get("security", spec["security"]) for name in requirement]


def test_phones_sign_their_requests_and_never_hold_a_bearer_token(spec):
    by_id = {op["operationId"]: _security(spec, op) for _, op in _operations(spec)}

    assert {op: by_id[op] for op in PHONE_OPERATIONS} == dict.fromkeys(
        PHONE_OPERATIONS, ["deviceSignature"]
    )
    assert {op for op, schemes in by_id.items() if not schemes} == OPEN_OPERATIONS
    assert "deviceSignature" in spec["components"]["securitySchemes"]


def test_role_restricted_operations_document_403(spec):
    restricted = [n for n in DEVICE_OPERATIONS if n != "POST /v1/devices/enroll"]
    ops = dict(_operations(spec))

    assert [name for name in restricted if "403" not in ops[name]["responses"]] == []


def test_a_device_is_pending_active_or_revoked(spec):
    device = spec["components"]["schemas"]["Device"]
    enrollment = spec["components"]["schemas"]["DeviceEnrollment"]

    assert device["properties"]["status"]["enum"] == ["pending", "active", "revoked"]
    assert set(enrollment["required"]) == {"code", "publicKeyDER", "proof"}
