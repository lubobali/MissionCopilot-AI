"""Run the real image with the real compose file and prove it works as deployed (#103 step 2.3).

Builds backend/ (or takes --image), starts a throwaway compose project on the given subnets, plays
the operator inside the network (setup, add-org, demo, signing key, pack), lets compose run the
migration and the API, then checks what a phone and an attacker would meet. Removes everything
afterwards, also when a check fails. Runs on the server, on a Mac, and in CI (step 3).

Usage (from the repo root; needs Docker and root or passwordless sudo, to give each secret file
the owner its container runs as):
  python3 scripts/container_check.py [--image IMAGE] [--port 8122]
      [--edge-subnet 192.168.252.64/26 --edge-gateway 192.168.252.65 --db-subnet 192.168.252.128/26]
"""

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mc_backup  # noqa: E402 - next to this script
import mc_deploy  # noqa: E402 - next to this script
import mc_restore  # noqa: E402 - next to this script
import nginx_check  # noqa: E402 - next to this script

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "deploy" / "compose.yaml"
HOSTNAME = "mc-check.example.org"
PHONE = "203.0.113.9"  # a documentation address (RFC 5737), sent as X-Forwarded-For
POSTGRES_UID, SERVER_UID = 10121, 10120  # deploy/compose.yaml: uids no other app uses


def values(args: argparse.Namespace, image: str, folder: Path) -> dict[str, str]:
    """The values file a real environment has, for this throwaway project."""
    return {
        "MC_ENV": "check",
        "MC_IMAGE": image,
        "MC_PORT": str(args.port),
        "MC_HOSTNAME": HOSTNAME,
        "MC_EDGE_SUBNET": args.edge_subnet,
        "MC_EDGE_GATEWAY": args.edge_gateway,
        "MC_DB_SUBNET": args.db_subnet,
        "MC_SECRETS": str(folder),
    }


def secrets_layout() -> dict[str, tuple[int, int]]:
    """Every secret path, its owner uid and mode, as deploy/README.md describes it."""
    return {
        ".": (0, 0o711),  # root's; the containers only need to pass through it
        "pg_admin_password": (POSTGRES_UID, 0o600),
        "admin_url": (SERVER_UID, 0o600),
        "addresses": (SERVER_UID, 0o700),
        "keys": (SERVER_UID, 0o700),
    }


def _sh(
    *command: str,
    env: dict[str, str] | None = None,
    check: bool = True,
    input_text: str | None = None,
) -> str:
    done = subprocess.run(  # noqa: S603
        command, env=env, input=input_text, capture_output=True, text=True, check=False
    )
    if check and done.returncode != 0:
        raise RuntimeError(f"{' '.join(command[:4])}...: {done.stderr.strip()[-400:]}")
    return done.stdout.strip()


def _chown(path: Path, uid: int, mode: int) -> None:
    sudo = [] if os.geteuid() == 0 else ["sudo", "-n"]
    _sh(*sudo, "chmod", oct(mode)[2:], str(path))
    _sh(*sudo, "chown", f"{uid}:{uid}", str(path))


def _write_owner_only(path: Path, text: str) -> None:
    """Owner-only from the first byte (never wider, then narrowed), and never over a file."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(text + "\n")


def make_secrets(folder: Path) -> None:
    """A throwaway password for this check's own Postgres. Compose secrets are files by design
    (production's are too, owner-only); this folder is removed when the check ends."""
    password = secrets.token_hex(24)
    _write_owner_only(folder / "pg_admin_password", password)
    url = f"postgresql://missioncopilot_admin:{password}@postgres:5432/postgres"
    _write_owner_only(folder / "admin_url", url)
    for name in ("addresses", "keys"):
        (folder / name).mkdir(mode=0o700)
    for name, (uid, mode) in secrets_layout().items():
        _chown(folder / name, uid, mode)


def get(port: int, path: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers)  # noqa: S310
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:  # noqa: S310 - loopback only
            return answer.status, dict(answer.headers), answer.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


class Check:
    def __init__(self, compose: list[str], env: dict[str, str], port: int):
        self.compose, self.env, self.port, self.failed = compose, env, port, 0

    def run(self, *args: str) -> str:
        return _sh(*self.compose, *args, env=self.env)

    def expect(self, what: str, ok: bool, seen: object = "") -> None:
        print(f"{'ok' if ok else 'FAILED'}: {what}{'' if ok else f' (saw {seen!r})'}")
        self.failed += not ok

    def audit_client(self) -> str:
        query = "SELECT client FROM audit_events WHERE kind='device_auth_failed' ORDER BY seq DESC"
        return self.run(
            "exec", "-T", "postgres", "psql", "-U", "missioncopilot_admin", "-d", "mc_directory",
            "-tAc", f"{query} LIMIT 1",
        )  # fmt: skip


def check_http(c: Check) -> None:
    status, headers, body = get(c.port, "/v1/health", {"Host": HOSTNAME})
    lower = {k.lower(): v for k, v in headers.items()}
    health = json.loads(body) if status == 200 else {}
    c.expect("health answers 200 for the real host name", status == 200, status)
    c.expect("health sends the server time", abs(health.get("time", 0) - time.time()) < 10, health)
    c.expect("no server header", "server" not in lower, lower.get("server"))
    c.expect("HSTS in production", "strict-transport-security" in lower)
    status, _, _ = get(c.port, "/v1/health", {"Host": "evil.example"})
    c.expect("an unknown host name gets 400", status == 400, status)
    status, _, body = get(c.port, "/v1/ready", {"Host": HOSTNAME})
    c.expect("ready: the directory database answers", status == 200, (status, body[:80]))


def check_container(c: Check) -> None:
    api = c.run("ps", "-q", "api")
    seen = json.loads(_sh("docker", "inspect", api))[0]
    host = seen["HostConfig"]
    c.expect("api is healthy", seen["State"]["Health"]["Status"] == "healthy", seen["State"])
    c.expect("api runs as 10120", seen["Config"]["User"] == "10120:10120", seen["Config"]["User"])
    c.expect("api root filesystem is read-only", host["ReadonlyRootfs"] is True)
    c.expect("api has no capabilities", host["CapDrop"] == ["ALL"] and not host["CapAdd"])
    reader = "import missioncopilot_backend.checklist_xlsx, pyxform; print('loaded')"
    loaded = c.run("exec", "-T", "api", "python", "-c", reader)  # pyxform, without its jar
    c.expect("the checklist reader (pyxform) loads in the image", loaded == "loaded", loaded)
    c.expect("api memory is capped", host["Memory"] == 512 * 1024 * 1024, host["Memory"])
    ports = c.run("port", "api", "8110")
    c.expect("api is published on loopback only", ports == f"127.0.0.1:{c.port}", ports)
    pg = json.loads(_sh("docker", "inspect", c.run("ps", "-q", "postgres")))[0]
    c.expect("postgres publishes no port", not pg["HostConfig"]["PortBindings"], pg["HostConfig"])
    who = pg["Config"]["User"]
    c.expect("postgres runs as its own uid 10121", who == f"{POSTGRES_UID}:{POSTGRES_UID}", who)
    caps = (pg["HostConfig"]["CapDrop"], pg["HostConfig"]["CapAdd"])
    c.expect("postgres has no capabilities", caps[0] == ["ALL"] and not caps[1], caps)
    zone = c.run(
        "exec", "-T", "postgres", "psql", "-U", "missioncopilot_admin", "-tAc", "SHOW timezone"
    )
    c.expect("postgres runs in UTC", zone == "UTC", zone)
    escape = "timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'"  # an outside address, by number
    reached = subprocess.run(  # noqa: S603
        [*c.compose, "exec", "-T", "postgres", "bash", "-c", escape],
        env=c.env, capture_output=True, check=False,
    ).returncode  # fmt: skip
    c.expect("postgres cannot reach the internet", reached != 0, reached)


def check_client_address(c: Check) -> None:
    # An unknown phone: refused (401) and recorded with the client address the server believed.
    headers = {"Host": HOSTNAME, "X-Device-Id": "x", "X-Forwarded-For": PHONE}
    get(c.port, "/v1/devices/me", headers)  # through host loopback: arrives from the gateway
    seen = c.audit_client()
    c.expect("through the trusted gateway, the audit log names the phone", seen == PHONE, seen)
    inside = (  # the same request from a container on the db network: not the trusted proxy
        "import urllib.request as u\n"
        f"r = u.Request('http://api:8110/v1/devices/me', headers={headers!r})\n"
        "try: u.urlopen(r, timeout=5)\nexcept Exception: pass\n"
    )
    c.run("run", "--rm", "--entrypoint", "python", "admin", "-c", inside)
    seen = c.audit_client()
    c.expect("from any other address, a forged X-Forwarded-For is ignored", seen != PHONE, seen)


def check_backup(c: Check, args: argparse.Namespace, image: str, folder: Path) -> None:
    """A real backup of this project into a throwaway local repository, then a restore of it
    into a throwaway Postgres (scripts/mc_backup.py), as the server does every night."""
    work = Path(tempfile.mkdtemp(prefix="mc-check-backup-"))
    try:
        lines = [f"{key}={value}" for key, value in values(args, image, folder).items()]
        (work / "values.env").write_text("\n".join(lines) + "\n")
        _write_owner_only(work / "restic-password", secrets.token_hex(24))
        (work / "repo").mkdir()
        where = ["--values", str(work / "values.env"), "--password-file",
                 str(work / "restic-password"), "--local-repo", str(work / "repo")]  # fmt: skip
        codes = [
            mc_backup.main([command, *where]) for command in ("init", "backup", "restore-check")
        ]
        c.expect(
            "a backup restores into a throwaway Postgres with every row", codes == [0, 0, 0], codes
        )
        # A disaster: the demo organization's database is gone. The runbook's restore brings it
        # back into the live stack, with its own rules (PUBLIC still may not connect).
        psql = ["exec", "-T", "postgres", "psql", "-U", "missioncopilot_admin", "-d", "postgres"]
        c.run("exec", "-T", "postgres", "dropdb", "--force", "-U", "missioncopilot_admin",
              "mc_org_kandor_works")  # fmt: skip
        restored = mc_restore.main([*where, "--yes-replace-live-data"])
        status, _, _ = get(c.port, "/v1/ready", {"Host": HOSTNAME})
        closed = "SELECT has_database_privilege('public', 'mc_org_kandor_works', 'CONNECT')"
        seen = (restored, status, c.run(*psql, "-tAc", closed))
        c.expect("a lost database is restored live, ready, and still closed to PUBLIC",
                 seen == (0, 200, "f"), seen)  # fmt: skip
    finally:
        _sh(*mc_backup.SUDO, "rm", "-rf", str(work), check=False)


def check_deploy(c: Check, args: argparse.Namespace, image: str, folder: Path) -> None:
    """scripts/mc_deploy.py with an image that cannot start: it must go back by itself."""
    work = Path(tempfile.mkdtemp(prefix="mc-check-deploy-"))
    broken = "missioncopilot-backend:check-broken"
    try:
        lines = [f"{key}={value}" for key, value in values(args, image, folder).items()]
        (work / "values.env").write_text("\n".join(lines) + "\n")
        recipe = f'FROM {image}\nCMD ["python", "-c", "raise SystemExit(3)"]\n'
        _sh("docker", "build", "-q", "-t", broken, "-", input_text=recipe)
        os.environ["MC_DEPLOY_WAIT"] = "40"
        deploy = ["deploy", "--values", str(work / "values.env"), "--allow-local", "--image"]
        went_back = mc_deploy.main([*deploy, broken])
        after = mc_deploy._values(work / "values.env")["MC_IMAGE"]  # noqa: SLF001
        c.expect("a deploy that cannot start goes back by itself", (went_back, after) == (1, image),
                 (went_back, after))  # fmt: skip
        c.expect("and a good one deploys", mc_deploy.main([*deploy, image]) == 0)
    finally:
        _sh("docker", "rmi", "-f", broken, check=False)
        shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--image")
    parser.add_argument("--port", type=int, default=8122)
    parser.add_argument("--edge-subnet", default="192.168.252.64/26")
    parser.add_argument("--edge-gateway", default="192.168.252.65")
    parser.add_argument("--db-subnet", default="192.168.252.128/26")
    args = parser.parse_args(argv)
    image = args.image or "missioncopilot-backend:check"
    if not args.image:
        _sh("docker", "build", "-q", "-t", image, str(ROOT / "backend"))
    folder = Path(tempfile.mkdtemp(prefix="mc-check-"))
    env = os.environ | values(args, image, folder)
    compose = ["docker", "compose", "-f", str(COMPOSE)]
    c = Check(compose, env, args.port)
    try:
        make_secrets(folder)
        c.run("config", "-q")
        c.run("up", "-d", "--wait", "postgres")
        for command in ("setup", "add-org kandor-works", "seed-demo", "make-signing-key"):
            c.run("run", "--rm", "admin", *command.split())
        c.run("run", "--rm", "admin", "publish-demo-pack")
        c.run("up", "-d", "--wait", "--wait-timeout", "120", "api")
        check_http(c)
        check_container(c)
        check_client_address(c)
        check_backup(c, args, image, folder)
        check_deploy(c, args, image, folder)
        nginx_check.start(Path(tempfile.mkdtemp(prefix="mc-check-nginx-")), HOSTNAME, args.port)
        nginx_check.wait(HOSTNAME)
        nginx_check.check(c, HOSTNAME, PHONE)  # last: it stops the API to see the 503
    except RuntimeError as error:
        c.expect("the deploy steps run", False, str(error))
    finally:
        nginx_check.stop()
        _sh(*compose, "--profile", "admin", "down", "-v", "--remove-orphans", env=env, check=False)
        sudo = [] if os.geteuid() == 0 else ["sudo", "-n"]
        _sh(*sudo, "rm", "-rf", str(folder), check=False)
        shutil.rmtree(folder, ignore_errors=True)
    print("OK: the container works as deployed" if not c.failed else f"FAILED: {c.failed} checks")
    return 1 if c.failed else 0


if __name__ == "__main__":
    sys.exit(main())
