"""The app's bill of materials (docs/sbom/app.cdx.json) must match what the app really runs: the
model's hash is the one we signed, and every Swift package pin is the revision the build resolves
(threat model T50, T52). These tests change one fact at a time and check the guard reports it."""

import copy
import json
from pathlib import Path

import pytest
from check_bom import BOM, PROJECT, RESOLVED, SIGNATURE, app_pins, load, problems

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def real():
    return load(ROOT / BOM), load(ROOT / SIGNATURE), load(ROOT / RESOLVED)


def model_of(bom: dict) -> dict:
    return next(c for c in bom["components"] if c["type"] == "machine-learning-model")


def library(bom: dict, name: str) -> dict:
    return next(c for c in bom["components"] if c["name"] == name)


def test_the_repo_bom_matches_the_signed_model_and_the_swift_pins(real):
    assert problems(*real) == []


def test_a_model_hash_that_is_not_the_signed_one_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    model_of(bom)["hashes"][0]["content"] = "0" * 64

    assert problems(bom, signature, resolved) == [
        "LFM2.5-1.2B-Instruct-4bit: weights hash is not the one in the signed bundle"
    ]


def test_a_model_without_its_full_revision_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    model_of(bom)["version"] = "dee2f8a2786e"

    assert problems(bom, signature, resolved) == [
        "LFM2.5-1.2B-Instruct-4bit: version must be the full 40-character revision"
    ]


def test_a_component_without_a_license_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    del library(bom, "GRDB.swift")["licenses"]

    assert problems(bom, signature, resolved) == ["GRDB.swift: no license recorded"]


def test_a_swift_pin_that_moved_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    resolved["pins"][0]["state"]["revision"] = "1" * 40

    assert problems(bom, signature, resolved) == [
        "grdb.swift: resolved at 1111111111111111111111111111111111111111, BOM says "
        "743e132654bb30469ce64e2294e14d8ad0aa4d95"
    ]


def test_a_swift_pin_missing_from_the_bom_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    bom["components"] = [c for c in bom["components"] if c["name"] != "SQLCipher.swift"]

    assert problems(bom, signature, resolved) == ["sqlcipher.swift: pinned but not in the BOM"]


def test_a_bom_without_the_model_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    bom["components"] = [c for c in bom["components"] if c["type"] != "machine-learning-model"]

    assert problems(bom, signature, resolved) == ["no machine-learning-model component"]


def test_the_bom_is_cyclonedx(real):
    bom, signature, resolved = copy.deepcopy(real)
    bom["bomFormat"] = "SPDX"

    assert problems(bom, signature, resolved) == ["not a CycloneDX 1.6 BOM"]


def test_the_bom_file_is_plain_json():
    assert json.loads((ROOT / BOM).read_text(encoding="utf-8"))["bomFormat"] == "CycloneDX"


def test_a_short_revision_is_caught_even_when_the_purl_agrees(real):
    bom, signature, resolved = copy.deepcopy(real)
    model_of(bom)["version"] = "dee2f8a2786e"
    model_of(bom)["purl"] = "pkg:huggingface/mlx-community/LFM2.5-1.2B-Instruct-4bit@dee2f8a2786e"

    assert problems(bom, signature, resolved) == [
        "LFM2.5-1.2B-Instruct-4bit: version must be the full 40-character revision"
    ]


def test_a_purl_at_another_revision_than_the_version_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    model_of(bom)["purl"] = "pkg:huggingface/mlx-community/LFM2.5-1.2B-Instruct-4bit@" + "2" * 40

    assert problems(bom, signature, resolved) == [
        "LFM2.5-1.2B-Instruct-4bit: version must be the full 40-character revision"
    ]


def test_an_older_cyclonedx_version_is_caught(real):
    bom, signature, resolved = copy.deepcopy(real)
    bom["specVersion"] = "1.5"

    assert problems(bom, signature, resolved) == ["not a CycloneDX 1.6 BOM"]


PROJECT_YML = """packages:
  # a comment
  GRDB:
    url: https://github.com/lubobali/GRDB.swift
    revision: {revision}
targets:
  MissionCopilot:
"""


def test_the_main_apps_package_pin_is_read_from_project_yml():
    pins = app_pins(PROJECT_YML.format(revision="a" * 40))

    assert pins == [
        {
            "identity": "GRDB (app)",
            "location": "https://github.com/lubobali/GRDB.swift",
            "state": {"revision": "a" * 40},
        }
    ]


def test_the_main_apps_pin_must_match_the_bom(real):
    bom, signature, resolved = copy.deepcopy(real)
    resolved["pins"] += app_pins(PROJECT_YML.format(revision="1" * 40))

    assert problems(bom, signature, resolved) == [
        f"GRDB (app): resolved at {'1' * 40}, BOM says {library(bom, 'GRDB.swift')['purl'][-40:]}"
    ]


def test_the_repo_app_and_spike_pins_both_match_the_bom(real):
    bom, signature, resolved = copy.deepcopy(real)
    resolved["pins"] += app_pins((ROOT / PROJECT).read_text(encoding="utf-8"))

    assert len(resolved["pins"]) == 3
    assert problems(bom, signature, resolved) == []
