"""Deploy one image to one MissionCopilot environment, and roll back if it does not come up
(#103 step 6).

deploy: the image must be ours and by digest. It is pulled (with the environment's own registry
login, MC_DOCKER_CONFIG, never root's shared one), written into the values file (the previous
image kept as MC_IMAGE_PREVIOUS), and `compose up --wait` runs the migration, then the API. Then
/v1/ready must answer 200 on loopback. If anything fails, the previous image goes back.
The limit, said plainly: the server refuses a database newer than its code (fail closed), so
once the new image's migrations have run, the old image cannot start; the script then says so
and the way back is the restore from the backup taken before (deploy/RUNBOOK.md).
rollback: put MC_IMAGE_PREVIOUS back.

Usage (from the repo root, as root):
  python3 scripts/mc_deploy.py deploy --values /srv/missioncopilot/staging/values.env \
      --image ghcr.io/lubobali/missioncopilot-backend@sha256:<digest>
  python3 scripts/mc_deploy.py rollback --values ...
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "deploy" / "compose.yaml"
OURS = re.compile(r"^ghcr\.io/lubobali/missioncopilot-backend@sha256:[0-9a-f]{64}$")


def check_image(image: str, allow_local: bool) -> str:
    if OURS.match(image) or (
        allow_local and re.fullmatch(r"missioncopilot-backend:[a-z0-9-]+", image)
    ):
        return image
    raise ValueError(f"deploy our image by digest (ghcr.io/lubobali/...@sha256:...), not {image!r}")


def with_image(values: str, image: str) -> str:
    """The values file with this image, the one it replaces kept as MC_IMAGE_PREVIOUS."""
    lines = [line for line in values.splitlines() if not line.startswith("MC_IMAGE_PREVIOUS=")]
    old = next(line.split("=", 1)[1] for line in lines if line.startswith("MC_IMAGE="))
    lines = [f"MC_IMAGE={image}" if line.startswith("MC_IMAGE=") else line for line in lines]
    return "\n".join([*lines, f"MC_IMAGE_PREVIOUS={old}"]) + "\n"


def migrations_applied(migrate_log: str) -> bool:
    """Whether the one-shot migrate service changed a database (no log: assume it did)."""
    results = re.findall(r"OK: [^:]+: applied (.+)", migrate_log)
    return not results or any(not result.startswith("nothing") for result in results)


def _values(path: Path) -> dict[str, str]:
    pairs = (line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    return {key.strip(): value.strip() for key, value in pairs}


def _write(path: Path, text: str) -> None:
    """Replace the values file in one step (a crash never leaves half a file), mode 600."""
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".values-")
    with os.fdopen(descriptor, "w") as file:
        file.write(text)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def _docker_env(values: Path) -> dict[str, str]:
    config = _values(values).get("MC_DOCKER_CONFIG")
    return os.environ | ({"DOCKER_CONFIG": config} if config else {})


def _compose(values: Path, *args: str) -> subprocess.CompletedProcess:
    command = ["docker", "compose", "--env-file", str(values), "-f", str(COMPOSE), *args]
    env = _docker_env(values)
    return subprocess.run(command, capture_output=True, text=True, env=env, check=False)  # noqa: S603


def _ready(values: Path) -> bool:
    found = _values(values)
    request = urllib.request.Request(  # noqa: S310 - loopback only
        f"http://127.0.0.1:{found['MC_PORT']}/v1/ready", headers={"Host": found["MC_HOSTNAME"]}
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:  # noqa: S310
            return answer.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _up(values: Path) -> bool:
    wait = os.environ.get("MC_DEPLOY_WAIT", "180")  # seconds; checks use less
    started = _compose(values, "up", "-d", "--wait", "--wait-timeout", wait, "api")
    return started.returncode == 0 and _ready(values)


def deploy(values: Path, image: str, allow_local: bool) -> int:
    check_image(image, allow_local)
    if OURS.match(image):  # with the environment's own registry login, never root's
        pulled = subprocess.run(["docker", "pull", "--quiet", image], capture_output=True,  # noqa: S603, S607
                                text=True, env=_docker_env(values), check=False)  # fmt: skip
        if pulled.returncode != 0:
            print(f"FAILED: pull: {pulled.stderr.strip()[-300:]}", file=sys.stderr)
            return 1
    previous = _values(values)["MC_IMAGE"]
    _write(values, with_image(values.read_text(), image))
    if _up(values):
        print(f"OK: {image} is up and ready (previous: {previous})")
        return 0
    migrated = migrations_applied(_compose(values, "logs", "--no-log-prefix", "migrate").stdout)
    print("FAILED: the new image did not come up ready; going back", file=sys.stderr)
    _write(values, with_image(values.read_text(), previous))
    if _up(values):
        print(f"ROLLED BACK: {previous} is up and ready again", file=sys.stderr)
        return 1
    why = "its migrations already ran: restore the backup" if migrated else "see the API's logs"
    print(
        f"FAILED: {previous} did not come back either ({why}; deploy/RUNBOOK.md)", file=sys.stderr
    )
    return 2


def rollback(values: Path) -> int:
    previous = _values(values).get("MC_IMAGE_PREVIOUS")
    if not previous:
        print("FAILED: no previous image recorded", file=sys.stderr)
        return 1
    _write(values, with_image(values.read_text(), previous))
    if _up(values):
        print(f"OK: rolled back to {previous}")
        return 0
    print(f"FAILED: {previous} did not come up ready (deploy/RUNBOOK.md)", file=sys.stderr)
    return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["deploy", "rollback"])
    parser.add_argument("--values", type=Path, required=True)
    parser.add_argument("--image")
    parser.add_argument("--allow-local", action="store_true", help="checks only")
    args = parser.parse_args(argv)
    try:
        if args.command == "rollback":
            return rollback(args.values)
        if not args.image:
            parser.error("deploy needs --image")
        return deploy(args.values, args.image, args.allow_local)
    except (ValueError, OSError, KeyError, StopIteration) as error:
        print(f"FAILED: {error!r}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
