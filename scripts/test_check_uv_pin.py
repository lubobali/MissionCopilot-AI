import pytest
from check_uv_pin import main, pinned_version, problems

pytestmark = pytest.mark.unit

PYPROJECT = '[project]\nname = "x"\n\n[tool.uv]\nrequired-version = "==0.13.6"\n'
READS_FILE = """jobs:
  test:
    steps:
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
        with:
          version-file: backend/pyproject.toml
          enable-cache: true
      - name: next step
        run: uv sync
"""
NO_PIN = """jobs:
  test:
    steps:
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
      - name: Audit
        with:
          version-file: backend/pyproject.toml
        run: uv run x
"""
DOCKERFILE = "FROM ghcr.io/astral-sh/uv:0.13.6@sha256:abc AS uv\nFROM python:3.12-slim\n"


def test_the_exact_pin_is_read():
    assert pinned_version(PYPROJECT) == "0.13.6"


@pytest.mark.parametrize(
    "line",
    ['required-version = ">=0.13"', 'required-version = "0.13.6"', "# no pin"],
)
def test_only_an_exact_pin_counts(line):
    assert pinned_version(f"[tool.uv]\n{line}\n") is None


def test_everything_on_the_same_version_passes():
    assert problems(PYPROJECT, {"ci.yml": READS_FILE}, {"Dockerfile": DOCKERFILE}) == []


def test_a_missing_pin_is_reported():
    assert problems("[project]\n", {}, {}) == [
        'backend/pyproject.toml: no exact pin; add [tool.uv] required-version = "==X.Y.Z"'
    ]


def test_a_setup_uv_step_without_the_version_file_is_reported():
    # The version-file further down belongs to the next step, not to setup-uv.
    assert problems(PYPROJECT, {"security.yml": NO_PIN}, {}) == [
        "security.yml: setup-uv on line 4 does not read backend/pyproject.toml (version-file)"
    ]


def test_a_setup_uv_step_with_its_own_other_version_is_reported():
    other = READS_FILE.replace("version-file: backend/pyproject.toml", 'version: "0.12.0"')

    assert problems(PYPROJECT, {"ci.yml": other}, {}) == [
        "ci.yml: setup-uv on line 4 does not read backend/pyproject.toml (version-file)"
    ]


def test_a_dockerfile_on_another_uv_is_reported():
    old = DOCKERFILE.replace("uv:0.13.6", "uv:0.11.17")

    assert problems(PYPROJECT, {}, {"Dockerfile": old}) == [
        "Dockerfile: uv image 0.11.17, but the pin is 0.13.6"
    ]


def test_a_dockerfile_without_a_uv_image_passes():
    assert problems(PYPROJECT, {}, {"Dockerfile": "FROM python:3.12-slim\n"}) == []


def _repo(root, workflow: str, dockerfile: str | None = None) -> None:
    (root / "backend").mkdir()
    (root / "backend" / "pyproject.toml").write_text(PYPROJECT)
    (root / ".github" / "workflows").mkdir(parents=True)
    (root / ".github" / "workflows" / "ci.yml").write_text(workflow)
    if dockerfile is not None:
        (root / "deploy").mkdir()
        (root / "deploy" / "Dockerfile").write_text(dockerfile)


def test_main_passes_on_a_pinned_repo(tmp_path, monkeypatch):
    _repo(tmp_path, READS_FILE, DOCKERFILE)
    monkeypatch.chdir(tmp_path)

    assert main() == 0


@pytest.mark.parametrize(
    ("workflow", "dockerfile"),
    [(NO_PIN, None), (READS_FILE, DOCKERFILE.replace("0.13.6", "0.11.17"))],
)
def test_main_fails_when_a_workflow_or_dockerfile_drifts(
    tmp_path, monkeypatch, workflow, dockerfile
):
    _repo(tmp_path, workflow, dockerfile)
    monkeypatch.chdir(tmp_path)

    assert main() == 1
