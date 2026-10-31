"""Concurrency regression for SKIP LOCKED sync outbox claims.

Requires migrations 001-004 and POS_TEST_DSN. Uses a disposable test database.
"""
import os
import threading
from concurrent.futures import ThreadPoolExecutor

import psycopg


DSN = os.environ.get("POS_TEST_DSN")
if not DSN:
    raise SystemExit("POS_TEST_DSN is required")


def main() -> None:
    node_id = None
    event_id = None
    aggregate_id = None
    locked = threading.Event()
    release_first = threading.Event()

    with psycopg.connect(DSN) as conn:
        row = conn.execute(
            """
            INSERT INTO pos.sync_nodes(node_type, node_code)
            VALUES ('central', 'SYNC007-CONCURRENCY')
            RETURNING id
            """
        ).fetchone()
        node_id = row[0]
        aggregate_id = conn.execute("SELECT gen_random_uuid()").fetchone()[0]
        event_id = conn.execute("SELECT gen_random_uuid()").fetchone()[0]
        conn.execute(
            """
            INSERT INTO pos.sync_outbox(
                node_id, event_id, aggregate_type, aggregate_id, event_type, payload
            ) VALUES (%s, %s, 'sale', %s, 'sale.created', '{"test":true}')
            """,
            (node_id, event_id, aggregate_id),
        )

    def first_worker():
        with psycopg.connect(DSN) as conn:
            with conn.transaction():
                row = conn.execute(
                    """
                    SELECT id, event_id, claim_token
                    FROM pos.claim_sync_outbox('worker-one', 1, 120)
                    """
                ).fetchone()
                if row is None:
                    raise AssertionError("first worker failed to claim the event")
                locked.set()
                if not release_first.wait(timeout=15):
                    raise AssertionError("test synchronization timed out")
                return row

    def second_worker():
        if not locked.wait(timeout=15):
            raise AssertionError("first worker did not acquire the row lock")
        with psycopg.connect(DSN) as conn:
            return conn.execute(
                """
                SELECT id, event_id, claim_token
                FROM pos.claim_sync_outbox('worker-two', 1, 120)
                """
            ).fetchall()

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first_future = pool.submit(first_worker)
            second_future = pool.submit(second_worker)
            second_rows = second_future.result(timeout=20)
            release_first.set()
            first_row = first_future.result(timeout=20)

        if second_rows:
            raise AssertionError("two workers claimed the same event concurrently")
        if first_row[1] != event_id:
            raise AssertionError("first worker claimed an unexpected event")

        with psycopg.connect(DSN) as conn:
            state = conn.execute(
                "SELECT status, claimed_by FROM pos.sync_outbox WHERE id=%s",
                (first_row[0],),
            ).fetchone()
            if state != ("sending", "worker-one"):
                raise AssertionError(f"unexpected final claim state: {state!r}")

    finally:
        release_first.set()
        if node_id is not None:
            with psycopg.connect(DSN) as conn:
                conn.execute("DELETE FROM pos.sync_outbox WHERE node_id=%s", (node_id,))
                conn.execute("DELETE FROM pos.sync_aggregate_counters WHERE node_id=%s", (node_id,))
                conn.execute("DELETE FROM pos.sync_nodes WHERE id=%s", (node_id,))

    print("SYNC CONCURRENCY PASS: SKIP LOCKED prevents duplicate concurrent claims")


if __name__ == "__main__":
    main()
