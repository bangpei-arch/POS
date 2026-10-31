from collections.abc import Iterator

from fastapi import Request
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


def create_pool(dsn: str, min_size: int, max_size: int) -> ConnectionPool:
    return ConnectionPool(
        conninfo=dsn,
        min_size=min_size,
        max_size=max_size,
        kwargs={"row_factory": dict_row, "options": "-c search_path=pos,public"},
        open=False,
    )


def get_connection(request: Request) -> Iterator:
    pool: ConnectionPool = request.app.state.db_pool
    with pool.connection() as connection:
        yield connection
