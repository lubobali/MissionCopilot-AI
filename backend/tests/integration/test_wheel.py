"""The built wheel is what runs on the server (#103 step 1.4, B2): it must hold every file the code
reads at run time, and work with no repo around it. The audit found the pack contract and the demo
dataset read from the repo folder: installed, publishing a pack crashed. This builds the real wheel
and runs from it, far from the repo."""

import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

pytestmark = [pytest.mark.unit, pytest.mark.integration]

BACKEND = Path(__file__).resolve().parents[2]
RUN_TIME_FILES = [
    "missioncopilot_backend/data/pack-sections.schema.json",
    "missioncopilot_backend/data/kandor-rural-roads.json",
    "missioncopilot_backend/db/sql/directory/0001_directory.sql",
    "missioncopilot_backend/db/sql/organization/0001_missions.sql",
]
FROM_THE_WHEEL = """
import json, sys
from missioncopilot_backend import admin, checklist_check
from missioncopilot_backend.pack_content import check_pack_files, pack_files
data = json.loads(admin.DATASET.read_text(encoding="utf-8"))
check_pack_files(pack_files(data))  # the pack contract, read from the wheel
print(json.dumps({"module": checklist_check.__file__, "mission": data["mission"]["id"]}))
"""


@pytest.fixture(scope="module")
def wheel(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("wheel")
    subprocess.run(  # noqa: S603 - fixed arguments, our own build
        ["uv", "build", "--wheel", "--quiet", "--out-dir", str(out), str(BACKEND)],  # noqa: S607
        check=True,
    )
    [built] = out.glob("missioncopilot_backend-*.whl")
    return built


def test_the_wheel_holds_every_file_the_code_reads(wheel):
    names = set(zipfile.ZipFile(wheel).namelist())

    assert [name for name in RUN_TIME_FILES if name not in names] == []


def test_publishing_checks_work_from_the_wheel_alone(wheel, tmp_path):
    # The wheel first on the path, run from an empty folder: the repo's own source is not used.
    env = os.environ | {"PYTHONPATH": str(wheel)}
    found = subprocess.run(  # noqa: S603 - our own interpreter and a fixed script
        [sys.executable, "-c", FROM_THE_WHEEL],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert found.returncode == 0, found.stderr
    answer = json.loads(found.stdout)
    assert answer["module"].startswith(str(wheel))
    assert answer["mission"] == admin_roads()


def admin_roads() -> str:
    from missioncopilot_backend.admin import ROADS

    return ROADS
