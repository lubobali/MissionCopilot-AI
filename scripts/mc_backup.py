"""Back up one MissionCopilot environment and prove a backup comes back (#103 step 6.4).

backup: the roles (with their password hashes) and every database (pg_dump -Fc), from inside the
environment's own Postgres container, plus its secrets folder, into the environment's own restic
repository (encrypted), then old snapshots are forgotten. The row counts of the tables that
matter, taken just before the dumps, go into the backup too.
restore-check: the latest snapshot is restored into a throwaway Postgres (no network, memory in a
tmpfs) and every table must have at least the rows counted at backup time (the dumps come after
the counts and these tables only grow). Nothing touches the live database.
init: create the repository (once).
verify: restic reads back a tenth of the stored data and checks it (weekly).

Everything runs in containers (Postgres's own tools, restic pinned by digest), so the server needs
nothing installed. Run as root (the secrets folder belongs to the containers' users).
Usage (from the repo root):
  python3 scripts/mc_backup.py backup --values /srv/missioncopilot/prod/values.env \
      --restic-env /srv/missioncopilot/prod/backup.env --password-file .../restic-password
  python3 scripts/mc_backup.py restore-check (same options)
  --local-repo PATH instead of --restic-env: a local repository (checks only).
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "deploy" / "compose.yaml"
POSTGRES_IMAGE = (
    "postgres:18.6-trixie@sha256:3a4264520e121176619f54ff867d12774bc81e95e7b84db58d63bccdb6144b81"
)
RESTIC_IMAGE = (
    "restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510"
)
ADMIN = "missioncopilot_admin"
NAME = re.compile(r"^mc_[a-z0-9_]+$")
# Postgres's own, plus the empty one the image creates for its superuser.
SYSTEM = {"postgres", "template0", "template1", ADMIN}
COUNTED = {
    "directory": ["organizations", "devices", "enrollment_codes", "audit_events"],
    "organization": ["missions", "mission_members", "packs", "pack_files", "pack_contents"],
}
# `check` alone reads no stored data; this reads back a tenth of it each time (a week apart).
VERIFY = ["check", "--read-data-subset", "10%"]
KEEP = ["--keep-daily", "7", "--keep-weekly", "5", "--keep-monthly", "6", "--prune"]
SUDO = [] if os.geteuid() == 0 else ["sudo", "-n"]


def database_names(listing: str) -> list[str]:
    """Our databases from a pg_database listing; anything unexpected stops the backup."""
    names = []
    for name in (line.strip() for line in listing.splitlines()):
        if not name or name in SYSTEM:
            continue
        if not NAME.match(name):
            raise ValueError(f"unexpected database name {name!r}; not backing up blind")
        names.append(name)
    return names


def shortfalls(counted: dict[str, dict[str, int]], found: dict[str, dict[str, int]]) -> list[str]:
    """What the restore lacks: a database or table missing, or fewer rows than were counted at
    backup time. An empty backup (no rows anywhere) is a failure too."""
    problems = [f"{db}: missing" for db in counted if db not in found]
    for db, tables in counted.items():
        for table, rows in tables.items():
            have = found.get(db, {}).get(table)
            if db in found and (have is None or have < rows):
                problems.append(f"{db}.{table}: {have} rows, {rows} counted at backup time")
    if not any(sum(tables.values()) for tables in counted.values()):
        problems.append("the backup holds no rows at all")
    return problems


def count_query(tables: list[str]) -> str:
    """One query counting each table (names come from COUNTED only)."""
    return " UNION ALL ".join(f"SELECT '{t}', count(*) FROM {t}" for t in tables)  # noqa: S608


def restic_command(
    env: str, env_file: str | None, password_file: str, args: list[str],
    local_repo: str | None = None, mounts: tuple[str, ...] = (), tag: bool = True,
) -> list[str]:  # fmt: skip
    command = ["docker", "run", "--rm", "-v", f"{password_file}:/run/restic-password:ro",
               "-e", "RESTIC_PASSWORD_FILE=/run/restic-password"]  # fmt: skip
    if local_repo:
        command += ["-v", f"{local_repo}:/repo", "-e", "RESTIC_REPOSITORY=/repo"]
    else:
        command += ["--env-file", str(env_file)]
    for mount in mounts:
        command += ["-v", mount]
    return [*command, RESTIC_IMAGE, *args, *(["--tag", f"mc-{env}"] if tag else [])]


def _run(command: list[str], **kwargs) -> str:
    done = subprocess.run(command, capture_output=True, text=True, check=False, **kwargs)  # noqa: S603
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(command[:4])}...: {done.stderr.strip()[-300:]}")
    return done.stdout.strip()


def _values(path: Path) -> dict[str, str]:
    pairs = (line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    return {key.strip(): value.strip() for key, value in pairs if not key.startswith("#")}


class Stack:
    """The environment's compose project, as its values file describes it."""

    def __init__(self, values: Path):
        self.values = _values(values)
        self.env = self.values["MC_ENV"]
        self.compose = ["docker", "compose", "--env-file", str(values), "-f", str(COMPOSE)]

    def psql(self, database: str, query: str) -> str:
        return _run([*self.compose, "exec", "-T", "postgres", "psql", "-U", ADMIN,
                     "-d", database, "-tAc", query])  # fmt: skip

    def dump(self, tool: list[str], target: Path) -> None:
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as out:
            done = subprocess.run([*self.compose, "exec", "-T", "postgres", *tool], stdout=out,  # noqa: S603
                                  stderr=subprocess.PIPE, check=False)  # fmt: skip
        if done.returncode != 0:
            raise RuntimeError(f"{tool[0]} failed: {done.stderr.decode()[-300:]}")


def _counts(psql, database: str) -> dict[str, int]:
    tables = COUNTED["directory" if database == "mc_directory" else "organization"]
    rows = (line.split("|") for line in psql(database, count_query(tables)).splitlines())
    return {table: int(count) for table, count in rows}


def backup(values: Path, restic: dict) -> None:
    stack = Stack(values)
    work = Path(tempfile.mkdtemp(prefix=f"mc-backup-{stack.env}-"))
    try:
        names = database_names(stack.psql("postgres", "SELECT datname FROM pg_database"))
        counts = {name: _counts(stack.psql, name) for name in names}
        (work / "counts.json").write_text(json.dumps(counts, indent=2))
        stack.dump(["pg_dumpall", "--roles-only", "-U", ADMIN], work / "roles.sql")
        for name in names:
            stack.dump(["pg_dump", "-Fc", "-U", ADMIN, "-d", name], work / f"{name}.dump")
        folder = stack.values["MC_SECRETS"]
        _run(["docker", "run", "--rm", "--network", "none", "-v", f"{folder}:/s:ro",
              "-v", f"{work}:/out", POSTGRES_IMAGE, "sh", "-c",
              "umask 077 && tar -C /s -cf /out/secrets.tar ."])  # fmt: skip
        host = ["--host", f"missioncopilot-{stack.env}"]
        mounts = (f"{work}:/backup:ro",)
        _run(restic_command(stack.env, args=["backup", "/backup", *host], mounts=mounts, **restic))
        _run(restic_command(stack.env, args=["forget", *host, *KEEP], **restic))
        print(f"OK: backed up {len(names)} databases, the roles and the secrets of {stack.env}")
    finally:
        _run([*SUDO, "rm", "-rf", str(work)])


def restore_check(values: Path, restic: dict) -> bool:
    env, target = Stack(values).env, Path(tempfile.mkdtemp(prefix="mc-restore-"))
    name = f"missioncopilot-{env}-restore-check"
    try:
        _run(restic_command(env, args=["restore", "latest", "--target", "/restore"],
                            mounts=(f"{target}:/restore",), **restic))  # fmt: skip
        _run(["docker", "run", "--detach", "--name", name, "--network", "none", "--memory", "512m",
              "--tmpfs", "/var/lib/postgresql", "-e", f"POSTGRES_USER={ADMIN}",
              "-e", f"POSTGRES_PASSWORD={secrets.token_hex(16)}",
              "-v", f"{target / 'backup'}:/restore:ro", POSTGRES_IMAGE])  # fmt: skip
        for _ in range(60):
            if subprocess.run(["docker", "exec", name, "pg_isready", "-q", "-U", ADMIN],  # noqa: S603, S607
                              check=False).returncode == 0:  # fmt: skip
                break
            time.sleep(1)
        restored = _run(["docker", "exec", name, "cat", "/restore/counts.json"])
        counted = json.loads(restored)
        _run(["docker", "exec", name, "psql", "-q", "-U", ADMIN, "-d", "postgres",
              "-f", "/restore/roles.sql"])  # fmt: skip
        for database in counted:
            _run(["docker", "exec", name, "createdb", "-U", ADMIN, database])
            _run(["docker", "exec", name, "pg_restore", "--exit-on-error", "-U", ADMIN,
                  "-d", database, f"/restore/{database}.dump"])  # fmt: skip
        _run(
            [
                "docker",
                "exec",
                name,
                "tar",
                "-tf",
                "/restore/secrets.tar",
                "./addresses/directory.url",
            ]
        )

        def psql(database: str, query: str) -> str:
            return _run(
                ["docker", "exec", name, "psql", "-U", ADMIN, "-d", database, "-tAc", query]
            )

        problems = shortfalls(counted, {db: _counts(psql, db) for db in counted})
        for line in problems:
            print(f"FAILED: restored {line}")
        ok = not problems
        print(
            f"{'OK' if ok else 'FAILED'}: restored {len(counted)} databases of {env} "
            "into a throwaway Postgres"
        )
        return ok
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)  # noqa: S603, S607
        _run([*SUDO, "rm", "-rf", str(target)])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["init", "backup", "restore-check", "verify"])
    parser.add_argument("--values", type=Path, required=True)
    parser.add_argument("--password-file", required=True)
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--restic-env")
    where.add_argument("--local-repo")
    args = parser.parse_args(argv)
    restic = {"env_file": args.restic_env, "password_file": args.password_file,
              "local_repo": args.local_repo}  # fmt: skip
    try:
        if args.command in ("init", "verify"):
            command = ["init"] if args.command == "init" else VERIFY
            _run(restic_command(Stack(args.values).env, args=command, tag=False, **restic))
            return 0
        if args.command == "backup":
            backup(args.values, restic)
            return 0
        return 0 if restore_check(args.values, restic) else 1
    except (RuntimeError, ValueError, OSError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
