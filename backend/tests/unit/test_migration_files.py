"""Migration files are numbered 0001, 0002, ... with no gaps or repeats, and each has a fingerprint
(SHA-256) so an edit after it ran is caught (#88)."""

import hashlib

import pytest

from missioncopilot_backend.db.migrations import MigrationError, load

pytestmark = pytest.mark.unit


def _files(folder, **files):
    for name, body in files.items():
        (folder / name).write_text(body, encoding="utf-8")
    return folder


def test_files_load_in_number_order(tmp_path):
    _files(tmp_path, **{"0002_b.sql": "SELECT 2;", "0001_a.sql": "SELECT 1;"})

    assert [(m.version, m.name) for m in load(tmp_path)] == [(1, "0001_a.sql"), (2, "0002_b.sql")]


def test_each_migration_carries_the_sha256_of_its_file(tmp_path):
    _files(tmp_path, **{"0001_a.sql": "CREATE TABLE a (id int);"})

    (migration,) = load(tmp_path)

    assert migration.sha256 == hashlib.sha256(b"CREATE TABLE a (id int);").hexdigest()
    assert migration.sql == "CREATE TABLE a (id int);"


@pytest.mark.parametrize(
    ("names", "problem"),
    [
        (["0001_a.sql", "0003_c.sql"], "0002"),  # a gap
        (["0002_b.sql"], "0001"),  # does not start at 1
        (["0001_a.sql", "0001_b.sql"], "twice"),  # a repeated number
        (["1_a.sql"], "1_a.sql"),  # not four digits
        (["0001_A b.sql"], "0001_A b.sql"),  # a name that is not lowercase words
    ],
)
def test_badly_numbered_or_named_files_are_refused(tmp_path, names, problem):
    _files(tmp_path, **dict.fromkeys(names, "SELECT 1;"))

    with pytest.raises(MigrationError, match=problem):
        load(tmp_path)


def test_other_files_in_the_folder_are_ignored(tmp_path):
    _files(tmp_path, **{"0001_a.sql": "SELECT 1;", "README.md": "notes", "__init__.py": ""})

    assert [m.name for m in load(tmp_path)] == ["0001_a.sql"]


def test_an_empty_folder_has_no_migrations(tmp_path):
    assert load(tmp_path) == []
