from pathlib import Path

import pytest
from check_file_size import find_oversized

pytestmark = pytest.mark.unit


def _write(path: Path, lines: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("x = 1\n" * lines)


def test_file_at_limit_passes(tmp_path):
    _write(tmp_path / "ok.py", 300)

    assert find_oversized([tmp_path / "ok.py"], limit=300) == []


def test_file_over_limit_is_reported_with_its_line_count(tmp_path):
    _write(tmp_path / "big.py", 301)

    assert find_oversized([tmp_path / "big.py"], limit=300) == [(tmp_path / "big.py", 301)]


def test_only_code_files_are_checked(tmp_path):
    _write(tmp_path / "notes.md", 999)
    _write(tmp_path / "View.swift", 301)

    found = find_oversized([tmp_path / "notes.md", tmp_path / "View.swift"], limit=300)

    assert found == [(tmp_path / "View.swift", 301)]
