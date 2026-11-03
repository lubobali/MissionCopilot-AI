"""One physical database per organization (ADR 0008, threat T31, #88), each with two roles of its
own: an owner that cannot log in (it owns the tables, migrations run as it) and an app login that
can only read and write rows. No query can join across organizations, and one organization's login
cannot even connect to another organization's database.

A fresh Postgres lets every login connect to every database (PUBLIC has CONNECT), so provisioning
revokes that on the new database and harden_cluster() does it for the built-in ones."""

import re
import secrets
from dataclasses import dataclass, field

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

from missioncopilot_backend.db.migrations import Migration, migrate

# Short enough that "mc_<id>_owner" stays inside Postgres's 63-character names.
ORG_ID = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")


@dataclass(frozen=True)
class OrgDatabase:
    org_id: str
    database: str
    owner_role: str
    app_role: str
    app_password: str = field(repr=False)  # shown once, to go into the secret store


def names_for(org_id: str) -> tuple[str, str, str]:
    """The database, owner role and app login of an organization."""
    if not ORG_ID.match(org_id):
        raise ValueError(f"organization id {org_id!r}: use 2 to 40 lowercase letters, digits, '-'")
    slug = org_id.replace("-", "_")
    return f"mc_org_{slug}", f"mc_{slug}_owner", f"mc_{slug}_app"


def harden_cluster(admin_url: str) -> None:
    """No login gets into the built-in databases just because it exists."""
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute("REVOKE CONNECT, TEMPORARY ON DATABASE postgres, template1 FROM PUBLIC")


def _password_hash(admin: psycopg.Connection, role: str, password: str) -> str:
    """SCRAM-SHA-256, made here by libpq, so the plain password never reaches the server's logs."""
    return admin.pgconn.encrypt_password(
        password.encode(), role.encode(), b"scram-sha-256"
    ).decode()


def provision(admin_url: str, org_id: str, migrations: list[Migration]) -> OrgDatabase:
    """Make the organization's database and roles, then bring its tables up to date. If any part
    fails, everything made so far is removed."""
    database, owner, app = names_for(org_id)
    password = secrets.token_hex(24)
    try:
        with psycopg.connect(admin_url, autocommit=True) as admin:
            admin.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(owner)))
            admin.execute(
                sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(
                    sql.Identifier(app), sql.Literal(_password_hash(admin, app, password))
                )
            )
            admin.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(database), sql.Identifier(owner)
                )
            )
            admin.execute(
                sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(sql.Identifier(database))
            )
            admin.execute(
                sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                    sql.Identifier(database), sql.Identifier(app)
                )
            )
        url = make_conninfo(admin_url, dbname=database)
        with psycopg.connect(url, autocommit=True) as db:
            for statement in (
                "REVOKE ALL ON SCHEMA public FROM PUBLIC",
                "GRANT USAGE ON SCHEMA public TO {app}",
                # Every table the owner makes later is usable, not alterable, by the app. Tables use
                # identity columns, which need no sequence grant (the tests insert without one).
                "ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public"
                " GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {app}",
            ):
                db.execute(
                    sql.SQL(statement).format(app=sql.Identifier(app), owner=sql.Identifier(owner))
                )
        migrate(url, migrations, role=owner)
    except BaseException:
        drop_organization(admin_url, org_id)
        raise
    return OrgDatabase(org_id, database, owner, app, password)


def drop_organization(admin_url: str, org_id: str) -> None:
    """Remove the organization's database and both roles (also cleans up a failed provisioning)."""
    database, owner, app = names_for(org_id)
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute(
            sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(database))
        )
        for role in (app, owner):
            admin.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role)))
