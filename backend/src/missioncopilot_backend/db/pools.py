"""Every connection pool the server opens (#103 step 4.4, S4). A pool keeps idle connections; when
Postgres restarts they die, and without a check the next request would be handed a dead one and
answer 500. psycopg's ConnectionPool.check_connection runs a quick check before handing a
connection out and replaces a broken one. tests/db/test_pool_restart.py checks every pool in the
server comes from here."""

from psycopg_pool import ConnectionPool

MAX_SIZE = 8  # per database; the connection math against max_connections is in deploy/README.md


def open_pool(url: str) -> ConnectionPool:
    return ConnectionPool(
        url, min_size=1, max_size=MAX_SIZE, open=True, check=ConnectionPool.check_connection
    )
