"""Copies the signed on-device model into the app at build time (#125, Lubo Nov 5: the model ships
inside the app, never a separate download).

Usage (an Xcode build phase):
    python3 bundle_model.py <configuration> <model folder> <signature> <dest>

Only the files the signature lists are copied: a Hub download also holds its own cache (`.cache`,
`.gitattributes`), and any file the signature does not list makes the app refuse the model. The
signature goes next to the folder, so the app checks the copy before trusting it (threat model T46).
Debug builds ship no model (the tests would copy 633 MB on every run); a Mac without the model (CI)
builds anyway and the app says the model is not in this build. Runs on the Mac's own python3, so
standard library only.
"""

from __future__ import annotations

import base64
import json
import shutil
import sys
from pathlib import Path


def signed_names(signature: Path) -> list[str]:
    """The file names the signature covers, sorted. The app verifies the signature itself."""
    envelope = json.loads(signature.read_text(encoding="utf-8"))["dsseEnvelope"]
    payload = json.loads(base64.b64decode(envelope["payload"]))
    return sorted(resource["name"] for resource in payload["predicate"]["resources"])


def _same(source: Path, copy: Path) -> bool:
    if not copy.is_file():
        return False
    a, b = source.stat(), copy.stat()
    return a.st_size == b.st_size and int(a.st_mtime) == int(b.st_mtime)


def bundle(configuration: str, model: Path, signature: Path, dest: Path) -> str:
    """Puts `model` (only its signed files) and `signature` into `dest`; returns what was done."""
    if configuration == "Debug":
        shutil.rmtree(dest, ignore_errors=True)
        return "skipped: Debug builds ship no model (the Lab imports one through Finder)"
    if not model.is_dir():
        shutil.rmtree(dest, ignore_errors=True)
        return f"warning: no model at {model}: this build ships without the AI model"
    names = signed_names(signature)
    missing = [name for name in names if not (model / name).is_file()]
    if missing:
        raise SystemExit(f"error: the model download lacks signed files: {', '.join(missing)}")
    target = dest / model.name
    target.mkdir(parents=True, exist_ok=True)
    for old in [p for p in target.rglob("*") if p.is_file()]:
        if str(old.relative_to(target)) not in names:
            old.unlink()
    for name in names:
        copy = target / name
        if not _same(model / name, copy):
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(model / name, copy)
    shutil.copy2(signature, dest / signature.name)
    return f"bundled {len(names)} files"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__)
        return 2
    configuration, model, signature, dest = argv
    print(bundle(configuration, Path(model), Path(signature), Path(dest)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
