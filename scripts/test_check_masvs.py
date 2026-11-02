"""The OWASP MASVS v2.1 matrix (docs/masvs.md) must list all 24 controls with their official wording
and an honest status, under the same rules as the threat model: built and spike name a real file,
planned names a phase or issue, and accepted or not applicable gives a reason."""

from pathlib import Path

import pytest
from check_masvs import OFFICIAL, parse_rows, problems

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
HEADER = "| Control | Requirement | Status | Proof, plan or reason |\n|---|---|---|---|\n"


def table(changes: dict[str, str] | None = None, skip: str = "") -> str:
    rows = [
        (changes or {}).get(cid, f"| {cid} | {text} | planned | #49 |")
        for cid, text in OFFICIAL.items()
        if cid != skip
    ]
    return HEADER + "\n".join(rows) + "\n"


def check(text: str, root: Path = ROOT) -> list[str]:
    return problems(parse_rows(text), root)


def test_the_official_list_has_24_controls_in_8_groups():
    assert len(OFFICIAL) == 24
    assert len({cid.rsplit("-", 1)[0] for cid in OFFICIAL}) == 8
    assert OFFICIAL["MASVS-STORAGE-1"] == "The app securely stores sensitive data."


def test_a_full_matrix_passes():
    assert check(table()) == []


def test_a_missing_control_is_reported():
    assert check(table(skip="MASVS-PRIVACY-4")) == ["MASVS-PRIVACY-4: missing"]


def test_reworded_requirements_are_reported():
    changed = {"MASVS-AUTH-2": "| MASVS-AUTH-2 | The app has a lock. | planned | #49 |"}

    assert check(table(changed)) == ["MASVS-AUTH-2: not the official wording"]


def test_a_duplicate_control_is_reported():
    text = (
        table()
        + "| MASVS-CODE-1 | The app requires an up-to-date platform version. | planned | #49 |\n"
    )

    assert check(text) == ["MASVS-CODE-1: duplicate"]


def test_built_needs_a_file_that_exists(tmp_path):
    (tmp_path / "real.py").write_text("", encoding="utf-8")
    good = {
        "MASVS-CODE-4": "| MASVS-CODE-4 | " + OFFICIAL["MASVS-CODE-4"] + " | built | `real.py` |"
    }
    bad = {
        "MASVS-CODE-4": "| MASVS-CODE-4 | " + OFFICIAL["MASVS-CODE-4"] + " | built | `gone.py` |"
    }

    assert check(table(good), tmp_path) == []
    assert check(table(bad), tmp_path)[0].startswith("MASVS-CODE-4: built, but no existing file")


@pytest.mark.parametrize("status", ["not applicable", "accepted"])
def test_not_applicable_and_accepted_need_a_reason(status):
    text = OFFICIAL["MASVS-PLATFORM-2"]
    short = {"MASVS-PLATFORM-2": f"| MASVS-PLATFORM-2 | {text} | {status} | none |"}
    reasoned = {
        "MASVS-PLATFORM-2": f"| MASVS-PLATFORM-2 | {text} | {status} | No WebViews in the app |"
    }

    assert check(table(short)) == [f"MASVS-PLATFORM-2: {status}, but no reason given"]
    assert check(table(reasoned)) == []


def test_a_row_with_a_stray_or_missing_cell_is_reported():
    text = OFFICIAL["MASVS-CODE-2"]
    extra = {"MASVS-CODE-2": f"| MASVS-CODE-2 | {text} | planned | Phase 8 | stray |"}
    short = {"MASVS-CODE-2": f"| MASVS-CODE-2 | {text} | planned |"}

    assert check(table(extra)) == ["MASVS-CODE-2: expected 4 cells, found 5"]
    assert check(table(short)) == ["MASVS-CODE-2: expected 4 cells, found 3"]


def test_an_unknown_status_is_reported():
    done = {"MASVS-CODE-3": "| MASVS-CODE-3 | " + OFFICIAL["MASVS-CODE-3"] + " | done | #44 |"}

    assert check(table(done)) == ["MASVS-CODE-3: unknown status 'done'"]


def test_the_repo_matrix_passes():
    assert check((ROOT / "docs" / "masvs.md").read_text(encoding="utf-8")) == []
