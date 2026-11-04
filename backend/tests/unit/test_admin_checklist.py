"""The admin's checklist commands (#93): convert-checklist checks an .xlsx form and writes the
pack's JSON without touching any database; every pack is checked against the contract before it is
published, the checklist as the phone checks it."""

import json

import pytest

from missioncopilot_backend import admin
from missioncopilot_backend.checklist_check import FormProblem
from missioncopilot_backend.pack_content import check_pack_files, pack_files
from tests.unit.test_checklist_xlsx import SETTINGS, _workbook

pytestmark = pytest.mark.unit

DEMO = json.loads(admin.DATASET.read_text(encoding="utf-8"))


def test_convert_checklist_writes_the_packs_json_and_names_what_it_dropped(tmp_path, capsys):
    out = tmp_path / "checklist.json"

    assert (
        admin.main(
            ["convert-checklist", str(_workbook(tmp_path / "f.xlsx")), "--out", str(out)], {}
        )
        == 0
    )

    form = json.loads(out.read_text(encoding="utf-8"))
    assert form["settings"]["form_id"] == "bridge_check" and len(form["survey"]) == 4
    printed = capsys.readouterr().out
    assert "OK: 3 questions and groups, 2 choices, English and French" in printed
    assert "dropped: survey: appearance" in printed


def test_convert_checklist_says_what_to_fix_and_fails(tmp_path, capsys):
    survey = [["type", "name", "label"], ["text", "a", "A"], ["text", "a", "Again"]]
    form = _workbook(tmp_path / "f.xlsx", survey=survey, settings=SETTINGS)

    assert admin.main(["convert-checklist", str(form)], {}) == 1
    assert 'FAILED: Row 2: the name "a" is used twice.' in capsys.readouterr().err


def test_the_demo_pack_passes_the_check_before_publishing():
    check_pack_files(pack_files(DEMO))


def test_a_pack_with_a_section_the_contract_refuses_is_never_published():
    files = pack_files(DEMO)
    ratings = json.loads(files["sections/ratings.json"])
    ratings["unexpected"] = 1
    files["sections/ratings.json"] = json.dumps(ratings).encode()
    with pytest.raises(ValueError, match="sections/ratings.json"):
        check_pack_files(files)


def test_a_pack_with_a_checklist_the_phone_would_refuse_is_never_published():
    form = json.loads(pack_files(DEMO)["forms/road-checklist.json"])
    form["survey"].append(dict(form["survey"][0]))  # a name used twice
    with pytest.raises(FormProblem, match="used twice"):
        check_pack_files(pack_files(DEMO, checklist=form))


def test_the_demo_pack_carries_the_converted_checklist(tmp_path):
    from missioncopilot_backend.checklist_xlsx import from_xlsx

    form, _ = from_xlsx(_workbook(tmp_path / "f.xlsx"))
    assert json.loads(pack_files(DEMO, checklist=form)["forms/road-checklist.json"]) == form


def test_publishing_checks_the_pack_before_it_reaches_any_database(tmp_path):
    form = json.loads(pack_files(DEMO)["forms/road-checklist.json"])
    form["survey"][0]["type"] = "select_one colours"  # no such list
    with pytest.raises(FormProblem, match="no choice list"):
        admin.publish_demo_pack("postgresql://nobody@127.0.0.1:1/none", tmp_path / "no-key.pem",
                                checklist=form)  # fmt: skip
