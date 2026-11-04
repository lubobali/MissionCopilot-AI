"""The pack contract and the demo dataset travel inside the package (#103 step 1.4, B2). On a
server there is no repo checkout: the code reads its own copies, and docs/ stays the one source
the phone and the people read. A copy that differs from docs/ fails here, so they never drift."""

from pathlib import Path

import pytest

from missioncopilot_backend import admin, checklist_check

pytestmark = pytest.mark.unit

REPO = Path(__file__).resolve().parents[3]
PACKAGE = REPO / "backend" / "src" / "missioncopilot_backend"
COPIES = {
    "docs/api/pack-sections.schema.json": "data/pack-sections.schema.json",
    "docs/demo/kandor-rural-roads.json": "data/kandor-rural-roads.json",
}


@pytest.mark.parametrize(("source", "copy"), COPIES.items())
def test_the_packaged_copy_is_byte_for_byte_the_docs_file(source, copy):
    packaged = PACKAGE / copy

    assert packaged.read_bytes() == (REPO / source).read_bytes(), f"copy {source} to {packaged}"


def test_the_code_reads_the_packaged_copies_not_the_repo():
    assert str(checklist_check.SCHEMA).startswith(str(PACKAGE / "data"))
    assert str(admin.DATASET).startswith(str(PACKAGE / "data"))
