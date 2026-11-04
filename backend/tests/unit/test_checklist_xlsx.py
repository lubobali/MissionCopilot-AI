"""An admin's .xlsx form becomes the pack's checklist JSON (#93): pyxform's reader, the English and
French columns kept, KoBo's spellings made the pack's, and anything the app does not read refused
with its sheet and row (the spreadsheet's own row number). The workbooks are built here in code."""

from pathlib import Path

import pytest
from openpyxl import Workbook

from missioncopilot_backend.checklist_check import FormProblem
from missioncopilot_backend.checklist_xlsx import from_xlsx

pytestmark = pytest.mark.unit

SURVEY = [
    [
        "type",
        "name",
        "label::English (en)",
        "label::French (fr)",
        "required",
        "relevant",
        "appearance",
    ],
    [
        "select_one yes_no",
        "started",
        "Has work started?",
        "Les travaux ont-ils commencé ?",
        "TRUE",
        None,
        "minimal",
    ],
    [None, None, None, None, None, None, None],  # an empty row: skipped, row numbers kept
    ["begin group", "bridge", "Bridge", None, None, "${started} = 'yes'", None],
    ["decimal", "deck_m", "Deck width (m)", "Largeur du tablier (m)", "yes", None, None],
    ["end group", None, None, None, None, None, None],
]
CHOICES = [
    ["list_name", "name", "label::English (en)", "label::French (fr)"],
    ["yes_no", "yes", "Yes", "Oui"],
    ["yes_no", "no", "No", "Non"],
]
SETTINGS = [
    ["form_id", "form_title", "version", "default_language"],
    ["bridge_check", "Bridge check", "2026110301", "English (en)"],
]


def _workbook(path: Path, survey=SURVEY, choices=CHOICES, settings=SETTINGS) -> Path:
    book = Workbook()
    book.remove(book.active)
    for name, rows in (("survey", survey), ("choices", choices), ("settings", settings)):
        if rows is not None:
            sheet = book.create_sheet(name)
            for row in rows:
                sheet.append(row)
    book.save(path)
    return path


def _refused(tmp_path: Path, **sheets) -> FormProblem:
    with pytest.raises(FormProblem) as refused:
        from_xlsx(_workbook(tmp_path / "form.xlsx", **sheets))
    return refused.value


def test_a_kobo_style_workbook_becomes_the_packs_checklist(tmp_path):
    form, dropped = from_xlsx(_workbook(tmp_path / "form.xlsx"))

    assert form == {
        "settings": {
            "form_id": "bridge_check",
            "form_title": "Bridge check",
            "version": "2026110301",
            "default_language": "English (en)",
        },
        "survey": [
            {
                "type": "select_one yes_no",
                "name": "started",
                "label": "Has work started?",
                "label::French (fr)": "Les travaux ont-ils commencé ?",
                "required": "yes",
            },
            {
                "type": "begin_group",
                "name": "bridge",
                "label": "Bridge",
                "relevant": "${started} = 'yes'",
            },
            {
                "type": "decimal",
                "name": "deck_m",
                "label": "Deck width (m)",
                "label::French (fr)": "Largeur du tablier (m)",
                "required": "yes",
            },
            {"type": "end_group"},
        ],
        "choices": [
            {"list_name": "yes_no", "name": "yes", "label": "Yes", "label::French (fr)": "Oui"},
            {"list_name": "yes_no", "name": "no", "label": "No", "label::French (fr)": "Non"},
        ],
    }
    assert dropped == ["survey: appearance (how a question looks, not what it checks)"]


def test_a_plain_label_column_is_english_and_short_language_names_are_read(tmp_path):
    survey = [["type", "name", "label", "hint::French"], ["text", "site", "Site", "Le site"]]
    form, _ = from_xlsx(_workbook(tmp_path / "form.xlsx", survey=survey, choices=None))

    assert form["survey"] == [
        {"type": "text", "name": "site", "label": "Site", "hint::French (fr)": "Le site"}
    ]
    assert form["choices"] == []


def test_a_language_other_than_english_and_french_is_refused(tmp_path):
    survey = [["type", "name", "label", "label::Spanish (es)"], ["text", "a", "A", "Una"]]
    problem = _refused(tmp_path, survey=survey)
    assert (
        problem.text
        == "survey sheet, column label::Spanish (es): only English and French are read."
    )


def test_a_column_that_changes_what_is_checked_is_refused(tmp_path):
    survey = [["type", "name", "label", "calculation"], ["text", "a", "A", "1 + 1"]]
    problem = _refused(tmp_path, survey=survey)
    assert problem.text == "survey sheet, column calculation: the app does not read this column."


def test_a_cell_the_app_cannot_read_is_refused_with_the_sheets_row(tmp_path):
    survey = [
        ["type", "name", "label", "required"],
        ["text", "a", "A", "yes"],
        [None] * 4,
        ["text", "b", "B", "maybe"],
    ]
    problem = _refused(tmp_path, survey=survey)
    assert problem.text == 'survey sheet, row 4: required must be yes or no, not "maybe".'


def test_the_form_is_checked_as_the_phone_checks_it(tmp_path):
    survey = [["type", "name", "label"], ["text", "a", "A"], ["calculate", "b", "B"]]
    problem = _refused(tmp_path, survey=survey)
    assert problem.kind == "schema" and "survey 2" in problem.text


def test_a_form_whose_default_language_is_not_english_is_refused(tmp_path):
    settings = [
        ["form_id", "form_title", "version", "default_language"],
        ["a", "A", "1", "French (fr)"],
    ]
    problem = _refused(tmp_path, settings=settings)
    assert problem.text == "settings sheet: the default language must be English (en)."


def test_settings_without_a_version_are_refused(tmp_path):
    settings = [["form_id", "form_title"], ["a", "A"]]
    problem = _refused(tmp_path, settings=settings)
    assert problem.text == "settings sheet: form_id, form_title and version are needed."


def test_a_file_that_is_not_a_workbook_is_refused(tmp_path):
    path = tmp_path / "form.xlsx"
    path.write_text("not a workbook")
    with pytest.raises(FormProblem) as refused:
        from_xlsx(path)
    assert refused.value.text == "This file is not an .xlsx form."
