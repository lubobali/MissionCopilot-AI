import json

import pytest
from jsonschema import Draft202012Validator
from make_pack_section_cases import (
    CASES,
    FIXTURE,
    SCHEMA,
    apply,
    build_cases,
    definition,
    fixture_files,
)

pytestmark = pytest.mark.unit

SECTIONS = {f"sections/{name}.json" for name in (
    "project", "components", "ratings", "results", "financing", "contracts", "milestones",
    "safeguards", "agreed-actions",
)} | {"forms/road-checklist.json"}  # fmt: skip


def _valid(path: str, document) -> bool:
    return Draft202012Validator(definition(path)).is_valid(document)


def test_the_cases_file_is_up_to_date():
    assert json.loads(CASES.read_text(encoding="utf-8")) == build_cases()


def test_the_fixture_has_the_nine_sections_and_the_checklist_and_each_is_valid():
    files = fixture_files()

    assert set(files) == SECTIONS
    assert all(_valid(path, document) for path, document in files.items())


def test_every_bad_case_is_refused_by_the_reference_validator_and_every_good_one_accepted():
    cases, files = build_cases(), fixture_files()

    for case in cases["bad"]:
        assert not _valid(case["file"], apply(files[case["file"]], case)), case
    for case in cases["good"]:
        assert _valid(case["file"], apply(files[case["file"]], case)), case


def test_every_object_gets_an_unknown_field_and_every_file_has_both_kinds():
    cases = build_cases()
    unknown = [c for c in cases["bad"] if c["op"] == "add"]

    assert {c["file"] for c in unknown} == SECTIONS
    assert {c["file"] for c in cases["good"]} == SECTIONS  # nothing over-strict goes unseen
    assert len(cases["bad"]) > 300 and len(cases["good"]) > 100


def test_the_cases_cover_every_keyword_the_schema_uses():
    errors: set[str] = set()
    cases, files = build_cases(), fixture_files()

    def collect(found) -> None:  # oneOf keeps its branches' errors in context
        for error in found:
            errors.add(str(error.validator))
            collect(error.context or [])

    for case in cases["bad"]:
        validator = Draft202012Validator(definition(case["file"]))
        collect(validator.iter_errors(apply(files[case["file"]], case)))

    used = {"type", "minLength", "required", "additionalProperties", "enum", "pattern", "items",
            "minimum", "minItems", "const", "oneOf", "exclusiveMinimum"}  # fmt: skip
    assert used - errors == set()


def test_applying_a_case_never_changes_the_fixture():
    files = fixture_files()
    before = json.dumps(files, sort_keys=True)

    for case in build_cases()["bad"][:50]:
        apply(files[case["file"]], case)

    assert json.dumps(files, sort_keys=True) == before
    assert FIXTURE.is_dir() and SCHEMA.is_file()
