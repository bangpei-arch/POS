import sys
import uuid
from pathlib import Path
from types import SimpleNamespace

import psycopg
from psycopg.rows import dict_row

# Reuse the existing isolated Store API fixture.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_store_sale_flow import store_api

# Import the sender script.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import sync_sender


def test_sender_recovers_event_after_worker_restart(store_api, monkeypatch):
    ctx = store_api
    outbox_id = uuid.uuid4()
    event_id = uuid.uuid4()
    aggregate_id = uuid.uuid4()

    # Create a dedicated event that is ordered before other eligible events.
    with psycopg.connect(ctx["dsn"]) as conn:
        conn.execute(
            """
            INSERT INTO pos.sync_outbox (
                id, node_id, event_id, aggregate_type, aggregate_id,
                event_type, payload, occurred_at
            )
            VALUES (
                %s, %s, %s, 'sale', %s,
                'sale.paid', '{}'::jsonb, '2000-01-01 00:00:00+00'
            )
            """,
            (outbox_id, ctx["node_id"], event_id, aggregate_id),
        )

    try:
        # Worker A claims the event, then stops before making an HTTP request.
        with psycopg.connect(ctx["dsn"], row_factory=dict_row) as conn:
            claimed = conn.execute(
                """
                SELECT *
                FROM pos.claim_sync_outbox_for_types(%s, %s, %s, %s)
                """,
                ("worker-a", ["sale.paid"], 1, 15),
            ).fetchone()

            assert claimed is not None
            assert claimed["id"] == outbox_id
            old_token = claimed["claim_token"]

            # Simulate lease expiry after the sender process stops.
            conn.execute(
                """
                UPDATE pos.sync_outbox
                SET lease_until = clock_timestamp() - interval '1 second'
                WHERE id = %s
                """,
                (outbox_id,),
            )

        # Fake Cloud response: no real network request is made.
        class FakeResponse:
            status_code = 200

            def __init__(self, received_event_id):
                self.received_event_id = received_event_id

            def raise_for_status(self):
                pass

            def json(self):
                return {
                    "results": [{
                        "event_id": self.received_event_id,
                        "status": "processed",
                        "processed_at": "2026-10-31T00:00:00Z",
                    }]
                }

        class FakeClient:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def post(self, url, **kwargs):
                body = kwargs["json"]
                received_event_id = body["events"][0]["event_id"]
                return FakeResponse(received_event_id)

        monkeypatch.setattr(sync_sender.httpx, "Client", FakeClient)
        monkeypatch.setattr(
            sync_sender,
            "get_token",
            lambda client, settings: "fake-test-token",
        )

        settings = SimpleNamespace(
            store_database_url=ctx["dsn"],
            cloud_api_base_url="http://fake-cloud",
            cloud_client_id="fake-client",
            cloud_client_secret="fake-secret",
            store_id=ctx["store_id"],
        )

        # Worker B recovers and sends the event.
        sent = sync_sender.run_once(settings, "worker-b", limit=1)
        assert sent == 1

        with psycopg.connect(ctx["dsn"], row_factory=dict_row) as conn:
            result = conn.execute(
                """
                SELECT status, attempts, claimed_by, claim_token
                FROM pos.sync_outbox
                WHERE id = %s
                """,
                (outbox_id,),
            ).fetchone()

            assert result["status"] == "sent"
            assert result["attempts"] == 2
            assert result["claimed_by"] is None
            assert result["claim_token"] is None

            attempts = conn.execute(
                """
                SELECT result, worker_id, claim_token
                FROM pos.sync_delivery_attempts
                WHERE outbox_id = %s
                """,
                (outbox_id,),
            ).fetchall()

            assert len(attempts) == 1
            assert attempts[0]["result"] == "success"
            assert attempts[0]["worker_id"] == "worker-b"
            assert attempts[0]["claim_token"] != old_token

    finally:
        # Remove only this test's event and its delivery records.
        with psycopg.connect(ctx["dsn"]) as conn:
            conn.execute(
                "DELETE FROM pos.sync_delivery_attempts WHERE outbox_id = %s",
                (outbox_id,),
            )
            conn.execute(
                "DELETE FROM pos.sync_outbox WHERE id = %s",
                (outbox_id,),
            )


def test_paid_sale_survives_api_restart_and_sender_does_not_resend(store_api, monkeypatch):
    """A committed sale/outbox survives a new API client and is sent once."""
    from fastapi.testclient import TestClient
    from test_store_sale_flow import app

    ctx = store_api

    # Start a dedicated API client, create a committed sale, then let its
    # lifespan shut down before constructing the replacement client.
    with TestClient(app) as initial_client:
        login = initial_client.post(
            "/api/v1/auth/login",
            json={"employee_code": ctx["employee_code"], "pin": "1234"},
        )
        assert login.status_code == 200
        headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

        opened = initial_client.post(
            "/api/v1/sessions/open",
            json={"opening_counted": "100000.00"},
            headers=headers,
        )
        assert opened.status_code == 200

        idempotency_key = f"restart-test-{uuid.uuid4()}"
        sale_response = initial_client.post(
            "/api/v1/sales",
            json={
                "lines": [{"product_id": str(ctx["product_id"]), "quantity": 1}],
                "payment_method_code": "CASH",
                "cash_received_amount": "20000.00",
            },
            headers={**headers, "Idempotency-Key": idempotency_key},
        )
        assert sale_response.status_code == 200
        sale_id = uuid.UUID(sale_response.json()["sale_id"])

    # A fresh TestClient starts after the first client's lifespan has stopped.
    with TestClient(app) as restarted_client:
        health_or_docs = restarted_client.get("/openapi.json")
        assert health_or_docs.status_code == 200

    with psycopg.connect(ctx["dsn"], row_factory=dict_row) as conn:
        before = conn.execute(
            """
            SELECT s.status, o.id AS outbox_id, o.event_id, o.status AS outbox_status
            FROM pos.pos_sales s
            JOIN pos.sync_outbox o
              ON o.aggregate_id = s.id AND o.event_type = 'sale.paid'
            WHERE s.id = %s
            """,
            (sale_id,),
        ).fetchone()

    assert before is not None
    assert before["status"] == "paid"
    assert before["outbox_status"] == "pending"

    # Make this test's event the oldest eligible sale event so a small claim
    # limit selects it ahead of pending rows left by other isolated fixtures.
    with psycopg.connect(ctx["dsn"]) as conn:
        conn.execute(
            """
            UPDATE pos.sync_outbox
            SET occurred_at = '2000-01-01 00:00:00+00'
            WHERE id = %s
            """,
            (before["outbox_id"],),
        )

    delivery_requests = []

    class FakeResponse:
        status_code = 200

        def __init__(self, event_id):
            self.event_id = event_id

        def raise_for_status(self):
            pass

        def json(self):
            return {
                "results": [{
                    "event_id": self.event_id,
                    "status": "processed",
                    "processed_at": "2026-10-31T00:00:00Z",
                }]
            }

    class FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def post(self, url, **kwargs):
            if url.endswith("/api/v1/sync/events:batch"):
                body = kwargs["json"]
                delivery_requests.append(body)
                return FakeResponse(body["events"][0]["event_id"])
            raise AssertionError(f"Unexpected HTTP request: {url}")

    monkeypatch.setattr(sync_sender.httpx, "Client", FakeClient)
    monkeypatch.setattr(
        sync_sender, "get_token",
        lambda client, settings: "fake-test-token",
    )
    settings = SimpleNamespace(
        store_database_url=ctx["dsn"],
        cloud_api_base_url="http://fake-cloud",
        cloud_client_id="fake-client",
        cloud_client_secret="fake-secret",
        store_id=ctx["store_id"],
    )

    # First sender process starts after the API restart and resumes the event.
    assert sync_sender.run_once(settings, "sender-after-restart", limit=1) == 1
    # A subsequent run may process other fixtures, but must not resend this ID.
    sync_sender.run_once(settings, "sender-next-run", limit=10)

    delivered_event_ids = [
        event["event_id"]
        for request in delivery_requests
        for event in request["events"]
    ]
    assert delivered_event_ids.count(str(before["event_id"])) == 1

    with psycopg.connect(ctx["dsn"], row_factory=dict_row) as conn:
        after = conn.execute(
            """
            SELECT s.status, o.status AS outbox_status, o.attempts,
                   count(*) FILTER (WHERE a.result = 'success') AS successful_deliveries
            FROM pos.pos_sales s
            JOIN pos.sync_outbox o
              ON o.aggregate_id = s.id AND o.event_type = 'sale.paid'
            LEFT JOIN pos.sync_delivery_attempts a ON a.outbox_id = o.id
            WHERE s.id = %s
            GROUP BY s.status, o.status, o.attempts
            """,
            (sale_id,),
        ).fetchone()

    assert after["status"] == "paid"
    assert after["outbox_status"] == "sent"
    assert after["attempts"] == 1
    assert after["successful_deliveries"] == 1
