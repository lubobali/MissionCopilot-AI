"""Restore one MissionCopilot environment's databases from its backup (#103 step 6.6, the runbook's
"restore"). This replaces the live data, so it runs only with --yes-replace-live-data.

The API is stopped; the snapshot (latest, or the one named) comes back from the environment's
restic repository; the roles are loaded (with their password hashes; existing roles stay); every
database is dropped and recreated with `pg_restore --create`, so it returns with its own settings
(owner, and who may connect: the isolation between organizations depends on it). Then the API
starts, and every table must have at least the rows counted at backup time. The secrets folder is
not touched: if it is lost too, deploy/RUNBOOK.md shows how to put back secrets.tar.

Usage (from the repo root, as root):
  python3 scripts/mc_restore.py --values /srv/missioncopilot/<env>/values.env \
      --restic-env /srv/missioncopilot/<env>/backup.env --password-file .../restic-password \
      [--snapshot ID] --yes-replace-live-data
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mc_backup import ADMIN, NAME, SUDO, Stack, _counts, _run, restic_command, shortfalls  # noqa: E402


def restore_commands(database: str) -> tuple[list[str], list[str]]:
    if not NAME.match(database):
        raise ValueError(f"unexpected database name {database!r}")
    drop = ["dropdb", "--force", "--if-exists", "-U", ADMIN, database]
    load = ["pg_restore", "--create", "--exit-on-error", "-U", ADMIN, "-d", "postgres"]
    return drop, load


def _pipe_in(stack: Stack, source: Path, command: list[str]) -> None:
    """A restored file (root's) into a tool inside the environment's Postgres container."""
    reader = subprocess.Popen([*SUDO, "cat", str(source)], stdout=subprocess.PIPE)  # noqa: S603
    done = subprocess.run([*stack.compose, "exec", "-T", "postgres", *command],  # noqa: S603
                          stdin=reader.stdout, capture_output=True, check=False)  # fmt: skip
    reader.wait()
    if done.returncode != 0 or reader.returncode != 0:
        raise RuntimeError(f"{command[0]} failed: {done.stderr.decode()[-300:]}")


def restore(values: Path, restic: dict, snapshot: str) -> bool:
    stack, target = Stack(values), Path(tempfile.mkdtemp(prefix="mc-restore-live-"))
    try:
        _run(restic_command(stack.env, args=["restore", snapshot, "--target", "/restore"],
                            mounts=(f"{target}:/restore",), **restic))  # fmt: skip
        files = target / "backup"
        counted = json.loads(_run([*SUDO, "cat", str(files / "counts.json")]))
        _run([*stack.compose, "stop", "api"])
        _pipe_in(stack, files / "roles.sql", ["psql", "-q", "-U", ADMIN, "-d", "postgres"])
        for database in counted:
            drop, load = restore_commands(database)
            _run([*stack.compose, "exec", "-T", "postgres", *drop])
            _pipe_in(stack, files / f"{database}.dump", load)
        _run([*stack.compose, "up", "-d", "--wait", "--wait-timeout", "180", "api"])
        found = {database: _counts(stack.psql, database) for database in counted}
        problems = shortfalls(counted, found)
        for problem in problems:
            print(f"FAILED: restored {problem}")
        if not problems:
            print(f"OK: {len(counted)} databases of {stack.env} restored from {snapshot}; API up")
        return not problems
    finally:
        _run([*SUDO, "rm", "-rf", str(target)])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--values", type=Path, required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--snapshot", default="latest")
    parser.add_argument("--yes-replace-live-data", action="store_true")
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--restic-env")
    where.add_argument("--local-repo")
    args = parser.parse_args(argv)
    if not args.yes_replace_live_data:
        print(
            "FAILED: this replaces the live databases; add --yes-replace-live-data", file=sys.stderr
        )
        return 1
    restic = {"env_file": args.restic_env, "password_file": args.password_file,
              "local_repo": args.local_repo}  # fmt: skip
    try:
        return 0 if restore(args.values, restic, args.snapshot) else 1
    except (RuntimeError, ValueError, OSError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
