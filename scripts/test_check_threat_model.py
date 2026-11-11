"""The threat model must not claim more than the repo shows: every threat row has a known status,
a "built" control points at a file that exists, and anything not built names the phase or issue
that fixes it. These tests feed the guard small tables and check what it reports."""

from pathlib import Path

import pytest
from check_threat_model import LAST_FINISHED_PHASE, parse_rows, problems

pytestmark = pytest.mark.unit

HEADER = "| ID | Kind | Threat | Control | Status | Test or phase |\n|---|---|---|---|---|---|\n"


def check(rows: str, root: Path) -> list[str]:
    return problems(parse_rows(HEADER + rows), root)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_real.py").write_text("", encoding="utf-8")
    return tmp_path


def test_a_complete_table_passes(repo):
    rows = (
        "| T01 | S | Fake phone | Enrollment | planned | #46 |\n"
        "| T02 | T | Changed payload | Signatures | built | `tests/test_real.py` |\n"
        "| T03 | I | Copied DB | SQLCipher | spike | `tests/test_real.py`, rebuild Phase 10 |\n"
        "| T04 | D | Lost unsynced | Deliberate | accepted | Accepted: safer than leaking |\n"
    )

    assert check(rows, repo) == []


def test_parse_reads_privacy_rows_and_ignores_other_tables(repo):
    text = HEADER + "| P01 | Linking | x | y | planned | Phase 10 |\n| LLM01 | a | b |\n"

    assert [row.id for row in parse_rows(text)] == ["P01"]


def test_unknown_status_is_reported(repo):
    assert "T01: unknown status 'done'" in check("| T01 | S | x | y | done | #46 |\n", repo)


def test_built_must_point_at_a_file_that_exists(repo):
    found = check("| T01 | T | x | y | built | `tests/missing.py` |\n", repo)

    assert found == ["T01: built, but no existing file is named (got: `tests/missing.py`)"]


def test_every_named_repo_file_must_exist_not_just_one(repo):
    where = "`tests/test_real.py`, `tests/renamed.py`, `docs/gone.md`"
    found = check(f"| T01 | T | x | y | built | {where} |\n", repo)

    assert found == ["T01: names a file that does not exist: tests/renamed.py, docs/gone.md"]


@pytest.mark.parametrize(
    "where", ["`/v1/health`, `tests/test_real.py`", "`X-App-Build`, `tests/test_real.py`"]
)
def test_routes_and_names_in_backticks_are_not_files(repo, where):
    assert check(f"| T01 | T | x | y | built | {where} |\n", repo) == []


def test_spike_needs_its_proof_and_the_phase_that_rebuilds_it(repo):
    assert check("| T01 | I | x | y | spike | `tests/test_real.py` |\n", repo) == [
        "T01: spike, but no phase or issue rebuilds it in the app"
    ]


def test_spike_proof_must_exist(repo):
    found = check("| T01 | I | x | y | spike | `tests/gone.py`, Phase 7 |\n", repo)

    assert found == [
        "T01: spike, but its proof file does not exist (got: `tests/gone.py`, Phase 7)"
    ]


def test_planned_needs_a_phase_or_issue(repo):
    found = check("| T01 | E | x | y | planned | later |\n", repo)

    assert found == ["T01: planned, but no phase or issue"]


def test_accepted_needs_a_reason(repo):
    found = check("| T01 | D | x | y | accepted | ok |\n", repo)

    assert found == ["T01: accepted, but no reason given"]


def test_duplicate_ids_are_reported(repo):
    rows = "| T01 | S | x | y | planned | #46 |\n| T01 | T | x | y | planned | #45 |\n"

    assert check(rows, repo) == ["T01: duplicate id"]


def test_a_row_with_missing_cells_is_reported(repo):
    assert check("| T01 | S | x | planned | #46 |\n", repo) == ["T01: expected 6 cells, found 5"]


def test_an_empty_model_is_a_problem(repo):
    assert problems([], repo) == ["no threat rows found"]


@pytest.mark.parametrize("phase", [4, 5, 6, 7, 8, 9])
@pytest.mark.parametrize("status", ["spike", "planned"])
def test_a_finished_phase_alone_is_no_plan(repo, status, phase):
    # Phases up to LAST_FINISHED_PHASE are done: "rebuild Phase 5" now means the row drifted.
    row = f"| T01 | I | x | y | {status} | `tests/test_real.py`, rebuild Phase {phase} |\n"

    assert check(row, repo) == [
        f"T01: {status}, but Phase {phase} is finished; name a later phase or an issue"
    ]


@pytest.mark.parametrize("where", ["Phase 4 and Phase 10", "Phase 4, #60", "Phase 10"])
def test_an_open_phase_or_an_issue_is_still_a_plan(repo, where):
    assert check(f"| T01 | I | x | y | spike | `tests/test_real.py`, {where} |\n", repo) == []


def test_every_phase_up_to_the_last_finished_one_counts_as_finished(repo):
    assert LAST_FINISHED_PHASE == 9
    found = check("| T01 | E | x | y | planned | Phase 0 |\n", repo)

    assert found == ["T01: planned, but Phase 0 is finished; name a later phase or an issue"]


def test_the_repo_model_passes():
    root = Path(__file__).resolve().parents[1]

    assert (
        problems(parse_rows((root / "docs" / "threat-model.md").read_text(encoding="utf-8")), root)
        == []
    )


def test_the_message_names_the_latest_finished_phase(repo):
    found = check("| T01 | E | x | y | planned | Phase 1, then Phase 3 |\n", repo)

    assert found == ["T01: planned, but Phase 3 is finished; name a later phase or an issue"]
