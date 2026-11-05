import base64
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from bundle_model import bundle, signed_names

pytestmark = pytest.mark.unit

SCRIPT = Path(__file__).resolve().parent / "bundle_model.py"
MODEL = "LFM2.5-1.2B-Instruct-4bit"


def _signature(path: Path, names: list[str]) -> Path:
    """A bundle shaped like OpenSSF Model Signing's: only the payload's file list matters here (the
    app checks the signature itself, before it trusts the model)."""
    payload = {"predicate": {"resources": [{"name": n, "digest": "0" * 64} for n in names]}}
    envelope = {"payload": base64.b64encode(json.dumps(payload).encode()).decode()}
    path.write_text(json.dumps({"dsseEnvelope": envelope}), encoding="utf-8")
    return path


@pytest.fixture
def source(tmp_path):
    """The model as the Hub download leaves it: the signed files plus its own hidden cache."""
    folder = tmp_path / "download" / MODEL  # not "models": macOS names ignore case, like "Models"
    (folder / ".cache" / "huggingface").mkdir(parents=True)
    (folder / ".cache" / "huggingface" / "CACHEDIR.TAG").write_text("cache")
    (folder / ".gitattributes").write_text("*.safetensors filter=lfs")
    for name in ("config.json", "model.safetensors", "tokenizer.json"):
        (folder / name).write_text(f"contents of {name}")
    return folder


@pytest.fixture
def sig(tmp_path):
    names = ["config.json", "model.safetensors", "tokenizer.json"]
    return _signature(tmp_path / f"{MODEL}.sig", names)


def _files(folder: Path) -> list[str]:
    return sorted(str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file())


def test_the_names_come_from_the_signature(sig):
    assert signed_names(sig) == ["config.json", "model.safetensors", "tokenizer.json"]


def test_staging_and_release_get_exactly_the_signed_files_and_the_signature(tmp_path, source, sig):
    # The download's cache is not signed: copying it would make the app refuse its own model.
    for config in ("Staging", "Release"):
        dest = tmp_path / config / "Models"
        assert bundle(config, source, sig, dest) == "bundled 3 files"
        assert _files(dest) == [
            f"{MODEL}.sig",
            f"{MODEL}/config.json",
            f"{MODEL}/model.safetensors",
            f"{MODEL}/tokenizer.json",
        ]
        assert (dest / MODEL / "model.safetensors").read_text() == "contents of model.safetensors"


def test_debug_ships_no_model(tmp_path, source, sig):
    # Debug builds run the tests on the Simulator: copying 633 MB into every test run is waste.
    dest = tmp_path / "Models"
    dest.mkdir()
    (dest / "stale").write_text("left from another build")

    assert bundle("Debug", source, sig, dest).startswith("skipped")
    assert not dest.exists()


def test_a_mac_without_the_model_builds_and_says_so(tmp_path, sig):
    # CI has no model (too big for git): the build goes on and the app says "not in this build".
    message = bundle("Release", tmp_path / "missing", sig, tmp_path / "Models")

    assert message.startswith("warning: ")
    assert not (tmp_path / "Models").exists()


def test_a_signed_file_missing_from_the_download_stops_the_build(tmp_path, source, sig):
    (source / "tokenizer.json").unlink()

    with pytest.raises(SystemExit, match="tokenizer.json"):
        bundle("Release", source, sig, tmp_path / "Models")


def test_files_left_from_an_older_model_are_removed(tmp_path, source, sig):
    dest = tmp_path / "Models"
    (dest / MODEL).mkdir(parents=True)
    (dest / MODEL / "old-weights.bin").write_text("from an older model")

    bundle("Release", source, sig, dest)

    assert "old-weights.bin" not in _files(dest / MODEL)


def test_an_unchanged_file_is_not_copied_again(tmp_path, source, sig):
    # 633 MB on every build would be slow: a file with the same size and time is left alone.
    dest = tmp_path / "Models"
    bundle("Release", source, sig, dest)
    copied = dest / MODEL / "model.safetensors"
    os.utime(copied, ns=(1, copied.stat().st_mtime_ns))  # mark it: a new copy would reset this

    bundle("Release", source, sig, dest)

    assert copied.stat().st_atime_ns == 1


def test_the_command_line_prints_for_xcode_and_exits_zero_when_the_model_is_missing(tmp_path, sig):
    missing, dest = str(tmp_path / "missing"), str(tmp_path / "M")
    result = subprocess.run(  # noqa: S603 (our own script, fixed arguments)
        [sys.executable, str(SCRIPT), "Release", missing, str(sig), dest],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout.startswith("warning: ")  # Xcode shows the line as a build warning


ROOT = Path(__file__).resolve().parents[1]


def _app_target():
    import yaml

    project = yaml.safe_load((ROOT / "ios" / "project.yml").read_text(encoding="utf-8"))
    return project["targets"]["MissionCopilot"]


def test_the_app_build_runs_the_bundler_with_the_signed_model_and_its_signature():
    target = _app_target()
    phases = [p for p in target.get("postBuildScripts", []) if "bundle_model.py" in p["script"]]

    assert len(phases) == 1
    script = phases[0]["script"]
    assert '"$CONFIGURATION"' in script
    assert f'"$SRCROOT/../models/mlx/{MODEL}"' in script
    assert f'"$SRCROOT/../docs/models/{MODEL}.sig"' in script
    assert '"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Models"' in script
    # The script reads ../models, outside the project: a sandboxed script could not.
    assert target["settings"]["base"]["ENABLE_USER_SCRIPT_SANDBOXING"] is False


def test_the_app_looks_for_the_same_model_the_build_copies():
    swift = (ROOT / "ios" / "MissionCopilot" / "Platform" / "AI" / "BundledModel.swift").read_text(
        encoding="utf-8"
    )

    assert f'static let name = "{MODEL}"' in swift
    assert 'static let folder = "Models"' in swift


def test_the_weights_never_enter_git():
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()

    assert "/models/" in ignored
    assert (ROOT / "docs" / "models" / f"{MODEL}.sig").is_file()  # the signature is in git
