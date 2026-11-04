"""Write the shared good and bad cases for the pack sections (#92).

Usage: uv run --directory backend python ../scripts/make_pack_section_cases.py
Writes docs/api/fixtures/pack-section-cases.json. Every case is one small change to a real file of
the signed Kandor pack (an unknown field, a field removed, a wrong type, an empty or changed value,
an empty list, plus named changes to the checklist that reach its limits and rules, #93), and the
reference JSON Schema validator decides whether it is good or bad. The
server's tests and the app's read the same file, so the phone's own schema check (PackSchema) must
agree with the reference on every case: never laxer, never stricter. Rerun after changing the
schema or the demo dataset; a test fails while the file is out of date.
"""

import copy
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "docs" / "api" / "pack-sections.schema.json"
FIXTURE = ROOT / "docs" / "api" / "fixtures" / "pack-v2-kandor"
CASES = ROOT / "docs" / "api" / "fixtures" / "pack-section-cases.json"
CHECKLIST = "forms/road-checklist.json"
UNKNOWN = "unexpected"
FRENCH = "::French (fr)"

Path_ = list[str | int]


def definition(path: str) -> dict[str, Any]:
    """The schema for one file of the pack: sections/<name>.json or forms/<name>.json."""
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    name = path.split("/")[-1].removesuffix(".json")
    return schema["$defs"][name] | {"$schema": schema["$schema"]}


def fixture_files() -> dict[str, Any]:
    """The pack's JSON files by path, read through the signed manifest."""
    manifest = json.loads((FIXTURE / "manifest.json").read_bytes())
    return {
        entry["path"]: json.loads((FIXTURE / "files" / entry["sha256"]).read_bytes())
        for entry in manifest["files"]
        if entry["mediaType"] == "application/json"
    }


def apply(document: Any, case: dict[str, Any]) -> Any:
    """The document with the case's change, on a copy."""
    changed = copy.deepcopy(document)
    *parents, last = case["path"]
    node = changed
    for step in parents:
        node = node[step]
    if case["op"] == "delete":
        del node[last]
    elif case["op"] == "repeat":  # the list there becomes its first item, count times
        node[last] = [copy.deepcopy(node[last][0]) for _ in range(case["count"])]
    elif isinstance(node, list) and last == len(node):  # "add" one more item at the end
        node.append(case["value"])
    else:  # "add" a field, or "set" a value
        node[last] = case["value"]
    return changed


def _leaf_values(value: Any) -> list[Any]:
    """Values to try in place of a leaf: other types, empty, negative, fractional, a trailing
    newline (the pattern's $ is a classic place for two validators to disagree)."""
    tries: list[Any] = [None, True, [], {}]
    if isinstance(value, str):
        tries += [1, "", "?", value + "\n", value + "x"]
    elif isinstance(value, bool) or value is None:
        tries += ["x", 1]
    else:
        tries += [str(value), -1, 0, 1.5, float(value), value + 1]
    return tries


def _changes(node: Any, path: Path_) -> list[dict[str, Any]]:
    if isinstance(node, dict):
        found = [{"path": [*path, UNKNOWN], "op": "add", "value": 1}]
        for key, child in node.items():
            found.append({"path": [*path, key], "op": "delete"})
            found += _changes(child, [*path, key])
        return found
    if isinstance(node, list):
        found = []
        if path:
            found.append({"path": path, "op": "set", "value": []})
        if node:
            one_more = copy.deepcopy(node[-1])
            found.append({"path": [*path, len(node)], "op": "add", "value": one_more})
        for index, child in enumerate(node):
            found.append({"path": [*path, index], "op": "delete"})
            found += _changes(child, [*path, index])
        return found
    return [{"path": path, "op": "set", "value": v} for v in _leaf_values(node)]


def _set(path: Path_, value: Any) -> dict[str, Any]:
    return {"path": path, "op": "set", "value": value}


def checklist_changes() -> list[tuple[str, dict[str, Any]]]:
    """Named changes to the Kandor checklist: its rows are a yes/no select (0), a decimal with a
    constraint (1), another select (2), a geopoint (3) and an image (4)."""
    end = ["survey", 5]  # one more row at the end of the survey
    group = {"type": "begin_group", "name": "bridge", "label": "Bridge"}
    language = ["settings", "default_language"]
    return [
        ("a group starts", _set(end, group)),
        ("a group ends", _set(end, {"type": "end_group"})),
        ("a group end with a label", _set(end, {"type": "end_group", "label": "Bridge"})),
        ("a note with no label", _set(end, {"type": "note", "name": "intro"})),
        ("a select written the expanded way", _set(["survey", 0], {
            "type": "select_one", "select_from_list_name": "yes_no", "name": "bridge_started",
            "label": "Has work on the Section 3 bridge started?"})),
        ("a French label", _set(["survey", 0, "label" + FRENCH], "Le pont a-t-il commencé ?")),
        ("a Spanish label", _set(["survey", 0, "label::Spanish (es)"], "¿Ha comenzado la obra?")),
        ("a French hint", _set(["survey", 1, "hint" + FRENCH], "Mesurer bord à bord")),
        ("a French constraint message",
         _set(["survey", 1, "constraint_message" + FRENCH], "Entre 0 et 20 m")),
        ("a French choice label", _set(["choices", 0, "label" + FRENCH], "Oui")),
        ("a calculate question", _set(["survey", 1, "type"], "calculate")),
        ("begin group written with a space", _set(end, group | {"type": "begin group"})),
        ("a select list name with capitals", _set(["survey", 0, "type"], "select_one Yes_no")),
        ("required as true", _set(["survey", 0, "required"], True)),
        ("required as no", _set(["survey", 0, "required"], "no")),
        ("required as maybe", _set(["survey", 0, "required"], "maybe")),
        ("an appearance column", _set(["survey", 0, "appearance"], "minimal")),
        ("a relevant expression", _set(["survey", 1, "relevant"], "${bridge_started} = 'yes'")),
        ("a default value", _set(["survey", 1, "default"], "7")),
        ("English named the default language", _set(language, "English (en)")),
        ("French named the default language", _set(language, "French (fr)")),
        ("200 questions", {"path": ["survey"], "op": "repeat", "count": 200}),
        ("201 questions", {"path": ["survey"], "op": "repeat", "count": 201}),
        ("500 choices", {"path": ["choices"], "op": "repeat", "count": 500}),
        ("501 choices", {"path": ["choices"], "op": "repeat", "count": 501}),
        ("a label of 1000 characters", _set(["survey", 0, "label"], "x" * 1000)),
        ("a label of 1001 characters", _set(["survey", 0, "label"], "x" * 1001)),
        ("a label of 1001 code points that reads as 501 letters",
         _set(["survey", 0, "label"], "e\u0301" * 500 + "x")),
        ("a hint of 1001 characters", _set(["survey", 1, "hint"], "x" * 1001)),
        ("an expression of 500 characters", _set(["survey", 1, "constraint"], ". > 0" + " " * 495)),
        ("an expression of 501 characters", _set(["survey", 1, "constraint"], ". > 0" + " " * 496)),
        ("a choice name with a space", _set(["choices", 0, "name"], "y es")),
        ("a name of 65 characters", _set(["survey", 0, "name"], "q" * 65)),
    ]  # fmt: skip


def build_cases() -> dict[str, list[dict[str, Any]]]:
    good, bad = [], []
    for path, document in sorted(fixture_files().items()):
        validator = Draft202012Validator(definition(path))
        named = [{"name": name} | change for name, change in checklist_changes()]
        for change in _changes(document, []) + (named if path == CHECKLIST else []):
            case = {"file": path} | change
            (good if validator.is_valid(apply(document, case)) else bad).append(case)
    return {"good": good, "bad": bad}


def _rows(cases: list[dict[str, Any]]) -> list[str]:
    rows = [json.dumps(case, ensure_ascii=False) for case in cases]
    return [row + ("," if index < len(rows) - 1 else "") for index, row in enumerate(rows)]


def main() -> None:
    cases = build_cases()
    lines = ['{"good": [', *_rows(cases["good"]), '], "bad": [', *_rows(cases["bad"]), "]}"]
    CASES.write_text("\n".join(lines) + "\n", encoding="utf-8")  # one case a line: readable diffs
    print(f"wrote {CASES.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
