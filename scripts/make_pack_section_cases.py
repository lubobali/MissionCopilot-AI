"""Write the shared good and bad cases for the pack sections (#92).

Usage: uv run --directory backend python ../scripts/make_pack_section_cases.py
Writes docs/api/fixtures/pack-section-cases.json. Every case is one small change to a real file of
the signed Kandor pack (an unknown field, a field removed, a wrong type, an empty or changed value,
an empty list), and the reference JSON Schema validator decides whether it is good or bad. The
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
UNKNOWN = "unexpected"

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


def build_cases() -> dict[str, list[dict[str, Any]]]:
    good, bad = [], []
    for path, document in sorted(fixture_files().items()):
        validator = Draft202012Validator(definition(path))
        for change in _changes(document, []):
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
