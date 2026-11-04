"""The image workflow (#103 steps 3.2 to 3.4, S11, S13): build natively for the server's
architecture, check the real container, scan it, and only from main push the very image that was
checked. Next to zizmor's lint, this pins the rules that matter here."""

import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

TEXT = (Path(__file__).resolve().parents[3] / ".github/workflows/image.yml").read_text("utf-8")
FLOW = yaml.safe_load(TEXT)
ON = FLOW[True]  # YAML 1.1 reads the key `on` as True
BUILD, PUBLISH = FLOW["jobs"]["build"], FLOW["jobs"]["publish"]
IMAGE = "missioncopilot-backend:ci"


def _runs(job: dict) -> str:
    return "\n".join(step.get("run", "") for step in job["steps"])


def _uses(job: dict) -> list[str]:
    return [step["uses"] for step in job["steps"] if "uses" in step]


def test_it_runs_for_the_backend_on_prs_and_main():
    paths = [
        "backend/**",
        "deploy/**",
        "scripts/container_check.py",
        "scripts/nginx_check.py",
        "scripts/render_nginx_site.py",
        ".github/workflows/image.yml",
    ]

    assert ON["push"] == {"branches": ["main"], "paths": paths}
    assert ON["pull_request"] == {"paths": paths}


def test_every_action_is_pinned_to_a_commit():
    # Every `uses:`, as a list item or as a key of a named step.
    lines = re.findall(r"^\s*(?:- )?(uses: .*)$", TEXT, flags=re.MULTILINE)

    assert len(lines) == 4, lines  # checkout, upload, download, attest
    pinned = re.compile(r"uses: \S+@[0-9a-f]{40} # v\S+")
    assert [line for line in lines if not pinned.fullmatch(line)] == []


def test_least_privilege_per_job():
    assert FLOW["permissions"] == {}
    assert BUILD["permissions"] == {"contents": "read"}
    assert PUBLISH["permissions"] == {
        "contents": "read",
        "packages": "write",
        "attestations": "write",
        "id-token": "write",
    }


def test_the_image_is_built_natively_for_the_server():
    assert BUILD["runs-on"] == PUBLISH["runs-on"] == "ubuntu-24.04"  # x86_64, no emulation
    assert f"docker build --platform linux/amd64 --tag {IMAGE} backend" in _runs(BUILD)


def test_the_built_image_passes_the_container_check_and_the_scan():
    runs = _runs(BUILD)

    assert f"python3 scripts/container_check.py --image {IMAGE}" in runs
    assert f"grype docker:{IMAGE} --only-fixed --fail-on high" in runs
    assert 'echo "${GRYPE_SHA256}  ${tarball}" | sha256sum --check' in runs  # pinned, not fetched
    assert re.fullmatch(r"[0-9a-f]{64}", FLOW["env"]["GRYPE_SHA256"])


def test_only_main_publishes_and_only_the_checked_image():
    assert PUBLISH["needs"] == "build"
    assert PUBLISH["if"] == "github.event_name == 'push' && github.ref == 'refs/heads/main'"
    assert "docker build" not in _runs(PUBLISH)  # never rebuilt: the artifact that passed
    assert "docker load" in _runs(PUBLISH)
    saved = [s for s in BUILD["steps"] if "docker save" in s.get("run", "")]
    assert [s["if"] for s in saved] == [PUBLISH["if"]]


def test_the_digest_is_recorded_and_attested():
    attest = [s for s in PUBLISH["steps"] if s.get("uses", "").startswith("actions/attest@")]

    assert len(attest) == 1
    assert attest[0]["with"]["subject-digest"] == "${{ steps.push.outputs.digest }}"
    assert "GITHUB_STEP_SUMMARY" in _runs(PUBLISH)


def test_no_cache_and_no_untrusted_text_in_scripts():
    assert not [u for u in _uses(BUILD) + _uses(PUBLISH) if "cache" in u or "setup-uv" in u]
    assert "${{" not in _runs(BUILD) + _runs(PUBLISH)  # values reach scripts through env only
    checkouts = [s for s in BUILD["steps"] if s.get("uses", "").startswith("actions/checkout@")]
    assert [s["with"]["persist-credentials"] for s in checkouts] == [False]


def test_the_registry_login_lasts_until_the_attestation_is_pushed_then_always_ends():
    # The first main run failed here: the push step logged out, then the attestation (which is
    # pushed to the registry too) found no credentials. Log out only at the very end, always.
    names = [step.get("name", step.get("uses", "")) for step in PUBLISH["steps"]]
    logout = PUBLISH["steps"][-1]

    assert "docker logout" not in _runs({"steps": PUBLISH["steps"][:-1]})
    assert logout["run"].strip() == "docker logout ghcr.io"
    assert logout["if"] == "always()"
    assert names.index("Attest where and how it was built") < len(names) - 1
