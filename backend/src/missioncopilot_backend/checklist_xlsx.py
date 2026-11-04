"""An admin's .xlsx form turned into the pack's checklist JSON (#93).

pyxform (ODK's own XLSForm reader, BSD-2) reads the workbook, so the sheets of real KoBo and ODK
forms read as they do there; this module then keeps what the app reads: the survey, choices and
settings sheets, English (the plain label column, or label::English) and French (label::French),
KoBo's spellings made the pack's ("begin group" is begin_group, TRUE is yes). A column that
changes what is checked but that the app does not read is refused, never dropped in silence; a
column about looks only (appearance) or KoBo's own bookkeeping ($kuid) is dropped and named.
Problems name the sheet and the spreadsheet's own row. The result is checked as the phone checks it.
"""

import re
from pathlib import Path

from pyxform.xls2json_backends import xlsx_to_dict

from missioncopilot_backend.checklist_check import FormProblem, check_form

TRANSLATED = re.compile(r"^(label|hint|constraint_message)::(.+)$")
FRENCH = "::French (fr)"
MAX_BYTES = 5 * 1024 * 1024  # a checklist is kilobytes; anything near this is not one (T56)
COLUMNS = {
    "survey": {"type", "name", "label", "hint", "required", "relevant", "constraint",
               "constraint_message", "default", "select_from_list_name"},
    "choices": {"list_name", "name", "label"},
}  # fmt: skip
LOOKS_ONLY = {"appearance": "how a question looks, not what it checks"}
SETTINGS = ("form_id", "form_title", "version")
ENGLISH = {"english", "en", "english (en)"}
FRENCH_NAMES = {"french", "fr", "french (fr)", "français", "français (fr)", "francais"}


def _key(sheet: str, header: str, dropped: list[str]) -> str | None:
    """The pack's name for a column, None when it is dropped, or a refusal."""
    if translated := TRANSLATED.match(header):
        base, language = translated.group(1), translated.group(2).strip().lower()
        if language in ENGLISH:
            return base
        if language in FRENCH_NAMES:
            return base + FRENCH
        text = f"{sheet} sheet, column {header}: only English and French are read."
        raise FormProblem("column", None, text)
    if header in COLUMNS[sheet]:
        return header
    if header in LOOKS_ONLY or header.startswith("$"):
        why = LOOKS_ONLY.get(header, "KoBo's own bookkeeping")
        if (note := f"{sheet}: {header} ({why})") not in dropped:
            dropped.append(note)
        return None
    text = f"{sheet} sheet, column {header}: the app does not read this column."
    raise FormProblem("column", None, text)


def _cell(sheet: str, number: int, key: str, value: str) -> str:
    if key == "type":
        value = " ".join(value.split())
        return {"begin group": "begin_group", "end group": "end_group"}.get(value, value)
    if key == "required":
        word = value.strip().lower()
        if word in ("yes", "true", "true()"):
            return "yes"
        if word in ("no", "false", "false()"):
            return "no"
        text = f'{sheet} sheet, row {number}: required must be yes or no, not "{value}".'
        raise FormProblem("cell", None, text)
    return value


def _rows(workbook: dict, sheet: str, dropped: list[str]) -> list[dict]:
    rows = []
    for index, cells in enumerate(workbook.get(sheet, [])):
        number = index + 2  # the spreadsheet's row: its first row is the header
        row: dict[str, str] = {}
        for header, value in cells.items():
            key = _key(sheet, header, dropped)
            if key is None:
                continue
            if key in row and row[key] != value:
                text = f"{sheet} sheet, row {number}: two different English {key}s."
                raise FormProblem("cell", None, text)
            row[key] = _cell(sheet, number, key, value)
        if row:
            rows.append(row)
    return rows


def _settings(workbook: dict, dropped: list[str]) -> dict:
    found = next((row for row in workbook.get("settings", []) if row), {})
    if not all(found.get(key) for key in SETTINGS):
        text = "settings sheet: form_id, form_title and version are needed."
        raise FormProblem("settings", None, text)
    settings = {key: found[key] for key in SETTINGS}
    if "default_language" in found:
        if found["default_language"].strip().lower() not in ENGLISH:
            text = "settings sheet: the default language must be English (en)."
            raise FormProblem("settings", None, text)
        settings["default_language"] = "English (en)"
    for key in found.keys() - set(settings):
        dropped.append(f"settings: {key} (not used by the app)")
    return settings


def from_xlsx(path: Path) -> tuple[dict, list[str]]:
    """The pack's checklist from an .xlsx form, and what was dropped (looks only), or a refusal."""
    if path.stat().st_size > MAX_BYTES:
        raise FormProblem("unreadable", None, "This file is over 5 MB: too big to be a checklist.")
    try:
        workbook = xlsx_to_dict(str(path))
    except Exception:  # noqa: BLE001 - pyxform raises several kinds for a file that is not a form
        raise FormProblem("unreadable", None, "This file is not an .xlsx form.") from None
    if not workbook.get("survey"):
        raise FormProblem("unreadable", None, "The workbook has no survey sheet.")
    dropped: list[str] = []
    form = {"settings": _settings(workbook, dropped), "survey": _rows(workbook, "survey", dropped),
            "choices": _rows(workbook, "choices", dropped)}  # fmt: skip
    check_form(form)
    return form, dropped
