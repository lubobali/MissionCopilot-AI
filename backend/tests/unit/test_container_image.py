"""The server image (#103 step 2.1, B3, S13, S14), checked from its Dockerfile: every base pinned by
digest, the same Python in both stages (the venv points at it), uv at the pinned version, only the
locked runtime packages, nothing but the package in the final image, a non-root user that cannot
change its own code, PID 1 that gets the stop signal, and a healthcheck."""

import json
import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

BACKEND = Path(__file__).resolve().parents[2]
DOCKERFILE = (BACKEND / "Dockerfile").read_text(encoding="utf-8")
IGNORE = (BACKEND / ".dockerignore").read_text(encoding="utf-8")
FROMS = re.findall(r"^FROM (\S+)(?: AS (\S+))?$", DOCKERFILE, flags=re.MULTILINE)
FINAL = DOCKERFILE[DOCKERFILE.rindex("\nFROM ") :]


def _instructions(text: str, name: str) -> list[str]:
    return re.findall(rf"^{name} (.+)$", text, flags=re.MULTILINE)


def test_every_image_is_pinned_by_digest():
    images = [image for image, _ in FROMS] + re.findall(r"--from=(\S+@\S+|\S+:\S+)", DOCKERFILE)

    assert images, "expected images"
    assert [image for image in images if not re.search(r"@sha256:[0-9a-f]{64}$", image)] == []


def test_both_stages_use_the_same_python():
    assert len(FROMS) == 2
    assert FROMS[0][0] == FROMS[1][0]
    assert FROMS[0][0].startswith("python:3.12.16-")  # fixes critical CVE-2026-115557
    assert FROMS[0][0].split("@")[0].endswith("-slim-trixie")


def test_uv_is_the_pinned_version():
    pin = re.search(r'required-version = "==([\d.]+)"', (BACKEND / "pyproject.toml").read_text())
    assert pin is not None

    assert f"ghcr.io/astral-sh/uv:{pin.group(1)}@sha256:" in DOCKERFILE


def test_only_the_locked_runtime_packages_are_installed():
    syncs = [line for line in DOCKERFILE.splitlines() if "uv sync" in line]

    assert len(syncs) == 2
    assert all("--locked" in line and "--no-editable" in line for line in syncs)
    assert "UV_NO_DEV=1" in DOCKERFILE
    assert "UV_PYTHON_DOWNLOADS=0" in DOCKERFILE  # the image's own Python, never a download


def test_the_final_image_holds_only_the_installed_environment():
    copies = _instructions(FINAL, "COPY")

    assert copies == ["--from=builder /app/.venv /app/.venv"]  # root-owned: code is read-only
    assert "uv" not in " ".join(_instructions(FINAL, "RUN"))


def test_it_runs_as_a_fixed_non_root_user():
    assert _instructions(FINAL, "USER") == ["10120:10120"]
    assert "--uid 10120" in FINAL


def test_the_server_is_pid_1_in_exec_form():
    [command] = _instructions(FINAL, "CMD")

    assert json.loads(command) == ["missioncopilot-backend"]


def test_the_healthcheck_asks_the_server_itself_without_extra_tools():
    [check] = _instructions(FINAL, "HEALTHCHECK")

    assert "CMD [" in check
    assert "http://127.0.0.1:8110/v1/health" in check
    assert "curl" not in check and "wget" not in check


def test_no_secret_is_baked_in():
    words = " ".join(_instructions(DOCKERFILE, "ENV") + _instructions(DOCKERFILE, "ARG"))

    assert not re.search(r"PASSWORD|SECRET|TOKEN|KEY|_URL", words, flags=re.IGNORECASE)


def test_the_build_context_lets_in_only_the_package():
    lines = [line.strip() for line in IGNORE.splitlines() if line.strip() and line[0] != "#"]

    assert lines[0] == "*"  # deny everything, then allow by name
    assert sorted(line for line in lines if line.startswith("!")) == [
        "!README.md",
        "!pyproject.toml",
        "!src/",
        "!uv.lock",
    ]


def test_the_lock_must_have_wheels_for_the_server_and_a_macs_docker():
    import tomllib

    uv = tomllib.loads((BACKEND / "pyproject.toml").read_text(encoding="utf-8"))["tool"]["uv"]

    assert uv["required-environments"] == [
        "sys_platform == 'linux' and platform_machine == 'x86_64'",  # the server, CI's runner
        "sys_platform == 'linux' and platform_machine == 'aarch64'",  # Docker on an Apple Mac
    ]


def test_the_unused_odk_validator_jar_is_removed():
    # pyxform bundles ODK_Validate.jar (old Jackson and commons-io, high CVEs). The backend only
    # reads workbooks (xlsx_to_dict) and the image has no Java, so it can never run: removed.
    # Only the jar: pyxform imports the odk_validate module at load time (container_check
    # proves pyxform still loads in the real image).
    builder = DOCKERFILE[: DOCKERFILE.rindex("\nFROM ")]
    site = "/app/.venv/lib/python3.12/site-packages"
    jar = f"{site}/pyxform/validators/odk_validate/bin/ODK_Validate.jar"

    assert f"\nRUN rm {jar}\n" in builder
    source = (BACKEND / "src" / "missioncopilot_backend").rglob("*.py")
    assert not [p for p in source if "odk_validate" in p.read_text(encoding="utf-8")]


def test_a_base_image_fix_names_an_exact_version_and_leaves_no_apt_lists():
    # #162: Grype found fixable highs in the base image's zlib1g before the Python image had
    # Debian's fix; the final image upgrades only named packages, each at an exact version,
    # then drops apt's lists.
    joined = FINAL.replace("\\\n", " ")  # a RUN that goes on over several lines, as one
    runs = [run for run in _instructions(joined, "RUN") if "apt-get" in run]
    upgrades = re.findall(r"\"?([\w.+-]+)=([^\s\"]+)", " ".join(runs))

    assert all("--only-upgrade" in run and "rm -rf /var/lib/apt/lists/*" in run for run in runs)
    assert ("zlib1g", "1:1.3.dfsg+really1.3.1-1+deb13u1") in upgrades


def test_the_image_label_states_the_repositorys_license():
    # The repository is all rights reserved (LICENSE), never MIT.
    assert 'org.opencontainers.image.licenses="LicenseRef-AllRightsReserved"' in DOCKERFILE
    assert "MIT" not in DOCKERFILE
