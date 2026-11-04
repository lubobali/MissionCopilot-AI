"""The server checks a checklist the way the phone does before it publishes one (#93, threat T54).

The forms in docs/api/fixtures/checklist-form-cases.json are the phone's too
(ios/MissionCopilotTests/ChecklistSharedCasesTests.swift): both must give the same verdict, so the
server never publishes a checklist every phone would refuse."""

import json
from pathlib import Path

import pytest

from missioncopilot_backend import checklist_expression as expression
from missioncopilot_backend.checklist_check import FormProblem, check_form, check_structure
from missioncopilot_backend.pack_content import pack_files

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[3]
SHARED = json.loads(
    (ROOT / "docs/api/fixtures/checklist-form-cases.json").read_text(encoding="utf-8")
)
DEMO = json.loads((ROOT / "docs/demo/kandor-rural-roads.json").read_text(encoding="utf-8"))
SETTINGS = {"form_id": "check", "form_title": "Check", "version": "1"}


def _form(case: dict) -> dict:
    return {
        "settings": SETTINGS,
        "survey": case["survey"],
        "choices": case.get("choices", SHARED["choices"]),
    }


@pytest.mark.parametrize("case", SHARED["cases"], ids=lambda case: case["name"])
def test_the_server_says_what_the_shared_file_says(case):
    try:
        check_structure(_form(case))
        found = None
    except FormProblem as problem:
        found = {"kind": problem.kind, "row": problem.row}
    assert found == case["problem"]


def test_the_kandor_checklist_passes_the_whole_check():
    form = json.loads(pack_files(DEMO)["forms/road-checklist.json"])
    check_form(form)


def test_a_form_the_contract_refuses_is_refused_with_where():
    form = json.loads(pack_files(DEMO)["forms/road-checklist.json"])
    form["survey"][1]["label"] = "x" * 1001
    with pytest.raises(FormProblem) as refused:
        check_form(form)
    assert refused.value.kind == "schema"
    assert "survey 2" in refused.value.text and "label" in refused.value.text


def test_each_problem_says_what_to_fix_in_plain_words():
    with pytest.raises(FormProblem) as refused:
        check_structure(_form({"survey": [{"type": "text", "name": "a", "label": "A"}] * 2}))
    assert refused.value.text == 'Row 2: the name "a" is used twice.'


# The expression reader, as the phone's (ChecklistExpressionTests)


@pytest.mark.parametrize(
    "text",
    [
        ". > 0 and . < 20",
        "selected(${q}, 'a')",
        "if(${a} = 'yes', 1, 0)",
        "-${a} <= -1.5",
        "string-length()",
        "today()",
        "(" * 32 + "1" + ")" * 32,
        " + ".join(["-1"] * 40),
    ],
)
def test_what_the_phone_reads_the_server_reads(text):
    assert expression.read(text)


@pytest.mark.parametrize(
    "text",
    [
        "jr:choice-name(${a}, '${a}')",
        "now()",
        "/data/a = 1",
        "${a} +",
        "${}",
        "width",
        "if(1, 2)",
        "${a} = 1)",
        "",
        "${a} & 1",
        "(" * 33 + "1" + ")" * 33,
        "1 + " * 125 + "1",
        "regex(., ${p})",
    ],
)
def test_what_the_phone_cannot_read_the_server_cannot_either(text):
    assert not expression.read(text)


@pytest.mark.parametrize("pattern", ["a" * 201, r"(a)\1", "(?<=a)b", "(?<!a)b", r"(?<x>a)\k<x>"])
def test_a_risky_pattern_is_refused(pattern):
    with pytest.raises(expression.UnsafePattern):
        expression.read(f"regex(., '{pattern}')")


def test_a_risky_pattern_in_a_rule_the_phone_cannot_read_is_kept_as_the_phone_keeps_it():
    assert not expression.read(r"jr:choice-name(., 'x') = 'y' and regex(., '(a)\1')")
