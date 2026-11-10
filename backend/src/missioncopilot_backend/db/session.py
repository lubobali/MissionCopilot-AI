"""One request's view of an organization's database: the caller, named to Postgres for one
transaction only, so row-level security decides what they see and a pooled connection never carries
them over (#88)."""

from collections.abc import Generator
from contextlib import contextmanager

import psycopg
from psycopg_pool import ConnectionPool


@contextmanager
def as_user(pool: ConnectionPool, user_id: str) -> Generator[psycopg.Connection]:
    """A connection inside one transaction in which Postgres knows the caller. The setting is local
    to the transaction: it ends with it, whatever happens."""
    with pool.connection() as conn, conn.transaction():
        conn.execute("SELECT set_config('app.user_id', %s, true)", [user_id])
        yield conn


@contextmanager
def as_manager(pool: ConnectionPool, user_id: str) -> Generator[psycopg.Connection]:
    """A connection in which Postgres knows the caller is a manager of this organization (#175):
    read-only policies let them see every mission. Only for a person whose dashboard session has
    the manager role; never from anything the browser sends."""
    with pool.connection() as conn, conn.transaction():
        conn.execute("SELECT set_config('app.user_id', %s, true)", [user_id])
        conn.execute("SELECT set_config('app.role', 'manager', true)")
        yield conn
