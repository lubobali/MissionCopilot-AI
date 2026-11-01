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
