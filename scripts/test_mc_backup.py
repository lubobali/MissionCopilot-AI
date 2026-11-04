import pytest
from mc_backup import (
    COUNTED,
    POSTGRES_IMAGE,
    RESTIC_IMAGE,
    count_query,
    database_names,
    restic_command,
    shortfalls,
)

pytestmark = pytest.mark.unit


def test_only_our_databases_are_dumped_and_their_names_are_checked():
    # The image also creates an empty database named after its superuser.
    listed = (
        "mc_directory\nmc_org_kandor_works\npostgres\ntemplate1\nmissioncopilot_admin\nmc_org_x\n"
    )

    assert database_names(listed) == ["mc_directory", "mc_org_kandor_works", "mc_org_x"]


@pytest.mark.parametrize("bad", ["mc_org_x; DROP TABLE packs", "mc_Org", "mc_org_x y", "mc-org"])
def test_a_strange_database_name_stops_the_backup(bad):
    with pytest.raises(ValueError, match="database name"):
        database_names(f"mc_directory\n{bad}\n")


def test_every_table_that_matters_is_counted():
    assert COUNTED["directory"] == ["organizations", "devices", "enrollment_codes", "audit_events"]
    assert COUNTED["organization"] == [
        "missions",
        "mission_members",
        "packs",
        "pack_files",
        "pack_contents",
    ]
    assert count_query(["missions", "packs"]) == (
        "SELECT 'missions', count(*) FROM missions UNION ALL SELECT 'packs', count(*) FROM packs"
    )


def test_restic_runs_pinned_with_a_password_file_and_this_environments_tag():
    command = restic_command("prod", "/srv/x/backup.env", "/srv/x/restic-password", ["snapshots"])

    assert command[:3] == ["docker", "run", "--rm"]
    assert RESTIC_IMAGE.startswith("restic/restic:0.19.1@sha256:")
    assert command[command.index("--env-file") :][:2] == ["--env-file", "/srv/x/backup.env"]
    assert "RESTIC_PASSWORD_FILE=/run/restic-password" in command
    assert command[-3:] == ["snapshots", "--tag", "mc-prod"]
    assert "--network" not in command  # the repository is off the box: it needs the internet


def test_a_local_repository_is_mounted_for_checks_only():
    command = restic_command("check", None, "/srv/x/pw", ["init"], local_repo="/srv/x/repo")

    assert "/srv/x/repo:/repo" in command and "RESTIC_REPOSITORY=/repo" in command
    assert "--env-file" not in command


def test_postgres_is_the_same_pinned_image_as_compose():
    from pathlib import Path

    compose = (Path(__file__).resolve().parents[1] / "deploy" / "compose.yaml").read_text()

    assert POSTGRES_IMAGE in compose


COUNTED_AT_BACKUP = {"mc_directory": {"devices": 3, "audit_events": 10}, "mc_org_a": {"packs": 2}}


def test_a_full_restore_has_no_shortfall():
    grown = {"mc_directory": {"devices": 3, "audit_events": 12}, "mc_org_a": {"packs": 2}}

    assert shortfalls(COUNTED_AT_BACKUP, grown) == []  # more rows: written after the counts


@pytest.mark.parametrize(
    ("found", "problem"),
    [
        ({"mc_directory": {"devices": 3, "audit_events": 10}}, "mc_org_a: missing"),
        ({"mc_directory": {"devices": 2, "audit_events": 10}, "mc_org_a": {"packs": 2}},
         "mc_directory.devices: 2 rows, 3 counted at backup time"),
        ({"mc_directory": {"audit_events": 10}, "mc_org_a": {"packs": 2}},
         "mc_directory.devices: None rows, 3 counted at backup time"),
    ],
)  # fmt: skip
def test_a_missing_database_table_or_row_is_a_shortfall(found, problem):
    assert problem in shortfalls(COUNTED_AT_BACKUP, found)


def test_an_empty_backup_is_a_failure():
    assert shortfalls({"mc_directory": {"devices": 0}}, {"mc_directory": {"devices": 0}}) == [
        "the backup holds no rows at all"
    ]


def test_verify_reads_back_a_tenth_of_the_stored_data():
    from mc_backup import VERIFY

    assert VERIFY == ["check", "--read-data-subset", "10%"]  # `check` alone reads no pack data


def test_a_live_restore_needs_the_explicit_flag(capsys):
    from mc_restore import main

    code = main(["--values", "/srv/x/values.env", "--password-file", "/srv/x/pw",
                 "--local-repo", "/srv/x/repo"])  # fmt: skip

    assert code == 1
    assert "--yes-replace-live-data" in capsys.readouterr().err


def test_a_database_comes_back_with_its_own_settings():
    from mc_restore import restore_commands

    drop, load = restore_commands("mc_org_kandor_works")

    assert drop == [
        "dropdb",
        "--force",
        "--if-exists",
        "-U",
        "missioncopilot_admin",
        "mc_org_kandor_works",
    ]
    # --create: the database itself as dumped (owner, and who may connect), not a default one.
    assert load == [
        "pg_restore",
        "--create",
        "--exit-on-error",
        "-U",
        "missioncopilot_admin",
        "-d",
        "postgres",
    ]


def test_restore_refuses_a_strange_database_name():
    from mc_restore import restore_commands

    with pytest.raises(ValueError, match="database name"):
        restore_commands("mc_x; DROP DATABASE mc_directory")


def test_the_live_restore_loads_the_roles_before_any_database(monkeypatch, tmp_path):
    # In the same cluster the roles still exist, so only this order test catches a missing step;
    # after a lost cluster the databases cannot load without their roles.
    import mc_restore

    steps = []
    monkeypatch.setattr(
        mc_restore, "_pipe_in", lambda stack, source, command: steps.append(source.name)
    )
    counts = '{"mc_directory": {}, "mc_org_a": {}}'
    monkeypatch.setattr(
        mc_restore, "_run", lambda command, **kw: counts if "counts.json" in command[-1] else ""
    )
    monkeypatch.setattr(mc_restore, "_counts", lambda psql, database: {})
    (tmp_path / "values.env").write_text("MC_ENV=check\nMC_SECRETS=/srv/x\n")

    restic = {"env_file": None, "password_file": "/srv/x/pw", "local_repo": "/srv/x/repo"}
    mc_restore.restore(tmp_path / "values.env", restic, "latest")

    assert steps == ["roles.sql", "mc_directory.dump", "mc_org_a.dump"]
