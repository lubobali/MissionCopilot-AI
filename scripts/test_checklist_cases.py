"""The checklist contract (#93): KoBo's flat rows, only the columns and types the app reads, English
and French, and limits. Each named change to the real Kandor checklist must land where a person
reading the contract would expect; the phone is then held to the same cases (PackSectionsTests)."""

import pytest
from make_pack_section_cases import CHECKLIST, build_cases, checklist_changes

pytestmark = pytest.mark.unit

GOOD = {
    "a group starts",
    "a group ends",
    "a select written the expanded way",
    "a French label",
    "a French hint",
    "a French constraint message",
    "a French choice label",
    "required as true",
    "required as no",
    "a relevant expression",
    "a default value",
    "English named the default language",
    "200 questions",
    "500 choices",
    "a label of 1000 characters",
    "an expression of 500 characters",
}
BAD = {
    "a Spanish label",
    "a calculate question",
    "begin group written with a space",
    "a select list name with capitals",
    "required as maybe",
    "an appearance column",
    "201 questions",
    "501 choices",
    "a label of 1001 characters",
    "an expression of 501 characters",
    "a hint of 1001 characters",
    "a choice name with a space",
    "French named the default language",
    "a group end with a label",
    "a name of 65 characters",
    "a note with no label",
    "a label of 1001 code points that reads as 501 letters",  # counted as the reference counts
}


def _verdicts() -> dict[str, str]:
    cases = build_cases()
    return {
        case["name"]: verdict
        for verdict in ("good", "bad")
        for case in cases[verdict]
        if case["file"] == CHECKLIST and "name" in case
    }


def test_every_named_change_has_a_verdict_written_here():
    names = {name for name, _ in checklist_changes()}
    assert names == GOOD | BAD
    assert not GOOD & BAD


@pytest.mark.parametrize("name", sorted(GOOD))
def test_the_contract_accepts(name):
    assert _verdicts()[name] == "good"


@pytest.mark.parametrize("name", sorted(BAD))
def test_the_contract_refuses(name):
    assert _verdicts()[name] == "bad"


def test_an_unknown_column_on_any_question_is_refused():
    unknown = [
        case
        for case in build_cases()["bad"]
        if case["file"] == CHECKLIST and case["path"][:1] == ["survey"] and case["op"] == "add"
        and case["path"][-1] == "unexpected"
    ]  # fmt: skip
    assert len(unknown) == 5  # one for each of the Kandor checklist's five questions
