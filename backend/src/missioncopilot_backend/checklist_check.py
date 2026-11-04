"""A checklist checked the way the phone checks it, before it goes into a pack (#93, threat T54).

First the pack's contract (the checklist's part of docs/api/pack-sections.schema.json), then what
the phone's ChecklistForm refuses: an unknown type, a name used twice, a select with no list or two,
a missing list, a group without its pair, groups deeper than 3, a ${name} that names no question, a
choice twice in a list, a regex() pattern that could hang the phone. Rows count from 1 in the
survey, as on the phone; docs/api/fixtures/checklist-form-cases.json holds the two to one answer.
"""

import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import best_match
from jsonschema.protocols import Validator

from missioncopilot_backend import checklist_expression as expression

SCHEMA = Path(__file__).resolve().parents[3] / "docs" / "api" / "pack-sections.schema.json"
SIMPLE = {"text", "integer", "decimal", "note", "date", "geopoint", "image"}
SELECTS = {"select_one", "select_multiple"}
MAX_DEPTH = 3
REFERENCE = re.compile(r"\$\{([^}]*)\}")


class FormProblem(ValueError):
    """Why a checklist was refused: a kind the phone also names, the survey row, and plain words."""

    def __init__(self, kind: str, row: int | None, text: str):
        super().__init__(text)
        self.kind, self.row, self.text = kind, row, text


def _at(kind: str, row: int, text: str) -> FormProblem:
    return FormProblem(kind, row, f"Row {row}: {text}")


def contract(name: str = "road-checklist") -> Validator:
    """The pack's contract for one file (a section's or the checklist's name, without .json)."""
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    return Draft202012Validator(schema["$defs"][name] | {"$schema": schema["$schema"]})


def check_form(form: dict) -> None:
    """The whole check before publishing: the contract, then the phone's own rules."""
    error = best_match(contract().iter_errors(form))
    if error is not None:
        steps = error.absolute_path  # inside a oneOf, error.path is only the branch's part
        where = ", ".join(str(step + 1) if isinstance(step, int) else step for step in steps)
        where = re.sub(r"(survey|choices), (\d+)", r"\1 \2", where) or "the top"
        message = error.message
        why = message if len(message) <= 160 else f"{error.validator} {error.validator_value}"
        text = f"The form does not match the pack's contract at {where}: {why}"
        raise FormProblem("schema", None, text)
    check_structure(form)


def _choices(form: dict) -> set[str]:
    lists: dict[str, list[str]] = {}
    for choice in form.get("choices", []):
        list_name, name = choice["list_name"], choice["name"]
        names = lists.setdefault(list_name, [])
        if name in names:
            text = f'The choice list "{list_name}" has "{name}" twice.'
            raise FormProblem("duplicateChoice", None, text)
        names.append(name)
    return set(lists)


def _select(kind: str, row: dict, number: int, lists: set[str]) -> None:
    parts = kind.split()
    if not parts or parts[0] not in SELECTS or len(parts) > 2:
        raise _at("unknownType", number, f'the question type "{kind}" is not supported.')
    named, listed = (parts[1] if len(parts) == 2 else None), row.get("select_from_list_name")
    chosen = named or listed
    if chosen is None or (named and listed and named != listed):
        raise _at("noList", number, "a select question needs exactly one choice list.")
    if chosen not in lists:
        raise _at("noSuchList", number, f'there is no choice list named "{chosen}".')


class _Rows:
    """Walks the survey rows in order, as the phone's ChecklistReader does."""

    def __init__(self, lists: set[str]):
        self.lists, self.names, self.open_groups = lists, set(), []

    def add(self, number: int, row: dict) -> None:
        kind = row.get("type", "")
        if kind == "end_group":
            if not self.open_groups:
                raise _at(
                    "unbalancedGroup", number, "a group is started or ended without its pair."
                )
            self.open_groups.pop()
            return
        if kind == "begin_group":
            if len(self.open_groups) >= MAX_DEPTH:
                raise _at("tooDeep", number, f"groups can be at most {MAX_DEPTH} deep.")
            self.open_groups.append(number)
        elif kind not in SIMPLE:
            _select(kind, row, number, self.lists)
        if row["name"] in self.names:
            raise _at("duplicateName", number, f'the name "{row["name"]}" is used twice.')
        self.names.add(row["name"])

    def finish(self) -> None:
        if self.open_groups:
            row = self.open_groups[-1]
            raise _at("unbalancedGroup", row, "a group is started or ended without its pair.")


def check_structure(form: dict) -> None:
    """The phone's ChecklistForm rules, in the phone's order: every row first, then the rules."""
    walk = _Rows(_choices(form))
    rows = list(enumerate(form["survey"], start=1))
    for number, row in rows:
        walk.add(number, row)
    walk.finish()
    for number, row in rows:  # a group's own row has only its relevant, as on the phone
        group = row.get("type") == "begin_group"
        for column in ("relevant",) if group else ("relevant", "constraint", "default"):
            if column in row:
                _rule(row[column], number, walk.names)


def _rule(text: str, number: int, names: set[str]) -> None:
    for name in REFERENCE.findall(text):
        if name not in names:
            raise _at("unknownReference", number, f"${{{name}}} names no question in this form.")
    try:
        expression.read(text)
    except expression.UnsafePattern:
        text = (
            f"this regex() pattern could make the phone hang. Keep it under "
            f"{expression.MAX_PATTERN} characters, with no backreferences or lookbehind."
        )
        raise _at("unsafePattern", number, text) from None
