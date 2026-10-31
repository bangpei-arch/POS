import base64
import os
import sys
import uuid
from pathlib import Path
from datetime import datetime, timezone
from decimal import Decimal

import psycopg
import pytest
from argon2 import PasswordHasher
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings
from app.main import app


@pytest.fixture
def cloud_api(tmp_path, monkeypatch):
    dsn = os.environ["CLOUD_DATABASE_URL"]
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_path = tmp_path / "private.pem"
    public_path = tmp_path / "public.pem"
    private_path.write_bytes(private.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ))
    public_path.write_bytes(private.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ))

    monkeypatch.setenv("JWT_PRIVATE_KEY_PATH", str(private_path))
    monkeypatch.setenv("JWT_PUBLIC_KEY_PATH", str(public_path))
    monkeypatch.setenv("JWT_KID", "test-rsa-key")
    monkeypatch.setenv("JWT_ISSUER", "pos-cloud-test")
    monkeypatch.setenv("JWT_AUDIENCE", "pos-cloud-api-test")
    monkeypatch.setenv("TOKEN_TTL_SECONDS", "300")
    get_settings.cache_clear()

    store_id, node_id, product_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    client_id = f"test-{uuid.uuid4().hex}"
    client_secret = "test-secret-" + uuid.uuid4().hex
    store_code = "T" + uuid.uuid4().hex[:10].upper()
    node_code = "N" + uuid.uuid4().hex[:10].upper()
    product_sku = "SKU-" + uuid.uuid4().hex[:10].upper()

    with psycopg.connect(dsn) as conn:
        conn.execute(
            "INSERT INTO cloud.stores(id,store_code,store_name) VALUES (%s,%s,%s)",
            (store_id, store_code, "Cloud API Test"),
        )
        conn.execute(
            "INSERT INTO cloud.sync_nodes(id,store_id,node_code) VALUES (%s,%s,%s)",
            (node_id, store_id, node_code),
        )
        conn.execute(
            """INSERT INTO cloud.node_credentials(node_id,client_id,client_secret_hash,scopes)
               VALUES (%s,%s,%s,%s)""",
            (node_id, client_id, PasswordHasher().hash(client_secret),
             ["sync:events:write", "sync:master:read", "sync:heartbeat:write"]),
        )
        conn.execute(
            "INSERT INTO cloud.products(id,sku,product_name) VALUES (%s,%s,%s)",
            (product_id, product_sku, "API Test Product"),
        )
        conn.execute(
            """INSERT INTO cloud.product_prices(product_id,price,valid_from,version)
               VALUES (%s,%s,now() - interval '1 hour',1)""",
            (product_id, Decimal("12345.00")),
        )

    with TestClient(app) as client:
        yield {
            "client": client,
            "dsn": dsn,
            "store_id": store_id,
            "node_id": node_id,
            "product_id": product_id,
            "client_id": client_id,
            "client_secret": client_secret,
            "product_sku": product_sku,
        }

    with psycopg.connect(dsn) as conn:
        conn.execute("DELETE FROM replica.payments WHERE source_store_id=%s", (store_id,))
        conn.execute("DELETE FROM replica.sale_lines WHERE source_store_id=%s", (store_id,))
        conn.execute("DELETE FROM replica.sales WHERE source_store_id=%s", (store_id,))
        conn.execute("DELETE FROM ingest.event_registry WHERE source_store_id=%s", (store_id,))
        conn.execute("DELETE FROM cloud.product_prices WHERE product_id=%s", (product_id,))
        conn.execute("DELETE FROM cloud.products WHERE id=%s", (product_id,))
        conn.execute("DELETE FROM cloud.node_credentials WHERE node_id=%s", (node_id,))
        conn.execute("DELETE FROM cloud.sync_nodes WHERE id=%s", (node_id,))
        conn.execute("DELETE FROM cloud.stores WHERE id=%s", (store_id,))
    get_settings.cache_clear()


def token_for(ctx, secret=None, scope=None):
    client = ctx["client"]
    basic = base64.b64encode(
        f'{ctx["client_id"]}:{secret or ctx["client_secret"]}'.encode()
    ).decode()
    form_data = {"grant_type": "client_credentials"}
    if scope:
        form_data["scope"] = scope
    response = client.post(
        "/api/v1/oauth/token",
        data=form_data,
        headers={"Authorization": f"Basic {basic}"},
    )
    return response


def test_client_credentials_master_bootstrap_and_heartbeat(cloud_api):
    ctx = cloud_api
    token_response = token_for(ctx)
    assert token_response.status_code == 200
    token_data = token_response.json()
    assert token_data["token_type"] == "Bearer"
    assert token_data["expires_in"] == 300
    assert "sync:master:read" in token_data["scope"]

    headers = {"Authorization": f'Bearer {token_data["access_token"]}'}
    bootstrap = ctx["client"].get("/api/v1/sync/master/bootstrap", headers=headers)
    assert bootstrap.status_code == 200
    body = bootstrap.json()
    assert body["store"]["id"] == str(ctx["store_id"])
    assert any(p["sku"] == ctx["product_sku"] and p["price"] == "12345.00"
               and p["base_uom_code"] == "pcs" and p["tax_rate"] == "0.0000"
               for p in body["products"])
    assert {m["code"] for m in body["payment_methods"]} >= {"CASH", "TRANSFER", "QRIS"}
    cash = next(m for m in body["payment_methods"] if m["code"] == "CASH")
    assert cash["is_cash"] is True and cash["method_type"] == "cash"

    heartbeat = ctx["client"].post(
        "/api/v1/sync/heartbeat",
        json={"app_version": "0.1.0"},
        headers=headers,
    )
    assert heartbeat.status_code == 200
    assert heartbeat.json()["status"] == "ok"

    jwks = ctx["client"].get("/.well-known/jwks.json")
    assert jwks.status_code == 200
    assert jwks.json()["keys"][0]["kid"] == "test-rsa-key"
    assert jwks.json()["keys"][0]["alg"] == "RS256"


def test_bad_secret_and_scope_escalation_are_rejected(cloud_api):
    ctx = cloud_api
    assert token_for(ctx, "wrong-secret").status_code == 401

    basic = base64.b64encode(
        f'{ctx["client_id"]}:{ctx["client_secret"]}'.encode()
    ).decode()
    response = ctx["client"].post(
        "/api/v1/oauth/token",
        data={"grant_type": "client_credentials", "scope": "sync:master:ack"},
        headers={"Authorization": f"Basic {basic}"},
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "invalid_scope"


def test_revoked_credential_invalidates_existing_token(cloud_api):
    ctx = cloud_api
    token_response = token_for(ctx)
    assert token_response.status_code == 200
    token = token_response.json()["access_token"]

    with psycopg.connect(ctx["dsn"]) as conn:
        conn.execute(
            "UPDATE cloud.node_credentials SET revoked_at=now() WHERE node_id=%s",
            (ctx["node_id"],),
        )

    response = ctx["client"].get(
        "/api/v1/sync/master/bootstrap",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 401


def test_token_cannot_use_unrequested_scope(cloud_api):
    ctx = cloud_api
    token_response = token_for(ctx, scope="sync:master:read")
    assert token_response.status_code == 200
    token = token_response.json()["access_token"]
    response = ctx["client"].post(
        "/api/v1/sync/heartbeat",
        json={"app_version": "0.1.0"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403


def test_sale_paid_receiver_is_idempotent_and_returns_final_ack(cloud_api):
    import hashlib
    import json

    ctx = cloud_api
    token_response = token_for(ctx, scope="sync:events:write")
    assert token_response.status_code == 200
    token = token_response.json()["access_token"]

    sale_id, terminal_id, cashier_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    line_id, product_id, payment_id, event_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "sale": {
            "sale_id": str(sale_id), "terminal_id": str(terminal_id), "cashier_id": str(cashier_id),
            "receipt_number": "TST-20261031-POS01-000001", "business_date": "2026-10-31",
            "currency_code": "IDR", "subtotal": "12500.00", "discount_total": "0.00",
            "tax_total": "0.00", "rounding_amount": "0.00", "grand_total": "12500.00",
            "paid_at": now,
        },
        "lines": [{
            "line_id": str(line_id), "product_id": str(product_id), "sku": "TEST-1",
            "name": "Test Product", "barcode": None, "quantity": 1, "unit_price": "12500.00",
            "gross_amount": "12500.00", "discount_amount": "0.00", "tax_code": "ZERO",
            "tax_rate": "0.0000", "tax_amount": "0.00", "line_total": "12500.00",
        }],
        "payments": [{
            "payment_id": str(payment_id), "method_code": "CASH", "method_name": "Tunai",
            "amount": "12500.00", "reference_number": None, "confirmed_at": now,
        }],
    }
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    event = {
        "event_id": str(event_id), "idempotency_key": f'{ctx["node_id"]}:{event_id}',
        "aggregate_type": "sale", "aggregate_id": str(sale_id), "aggregate_version": 1,
        "event_type": "sale.paid", "schema_version": 1, "occurred_at": now,
        "payload_sha256": hashlib.sha256(raw).hexdigest(), "payload": payload,
    }
    batch = {
        "protocol_version": 1, "source_node_id": str(ctx["node_id"]),
        "source_store_id": str(ctx["store_id"]), "worker_id": "test-sender", "events": [event],
    }
    headers = {"Authorization": f"Bearer {token}"}
    first = ctx["client"].post("/api/v1/sync/events:batch", json=batch, headers=headers)
    assert first.status_code == 200, first.text
    assert first.json()["results"][0]["status"] == "processed"
    second = ctx["client"].post("/api/v1/sync/events:batch", json=batch, headers=headers)
    assert second.status_code == 200, second.text
    assert second.json()["results"][0]["status"] == "already_processed"

    # Reusing only one side of the event identity must not ACK a different event.
    key_collision = {**event, "event_id": str(uuid.uuid4())}
    key_collision_batch = {**batch, "events": [key_collision]}
    key_conflict = ctx["client"].post(
        "/api/v1/sync/events:batch", json=key_collision_batch, headers=headers
    )
    assert key_conflict.status_code == 409

    event_collision = {**event, "idempotency_key": f'{ctx["node_id"]}:different-key'}
    event_collision_batch = {**batch, "events": [event_collision]}
    event_conflict = ctx["client"].post(
        "/api/v1/sync/events:batch", json=event_collision_batch, headers=headers
    )
    assert event_conflict.status_code == 409

    with psycopg.connect(ctx["dsn"]) as conn:
        assert conn.execute(
            "SELECT count(*) FROM replica.sales WHERE source_store_id=%s AND source_sale_id=%s",
            (ctx["store_id"], sale_id),
        ).fetchone()[0] == 1
        assert conn.execute(
            "SELECT count(*) FROM ingest.event_registry WHERE source_node_id=%s AND event_id=%s AND status='processed'",
            (ctx["node_id"], event_id),
        ).fetchone()[0] == 1


def test_sale_paid_receiver_rejects_hash_and_source_mismatch(cloud_api):
    import hashlib
    import json

    ctx = cloud_api
    token = token_for(ctx, scope="sync:events:write").json()["access_token"]
    payload = {"sale": {}, "lines": [], "payments": []}
    now = datetime.now(timezone.utc).isoformat()
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    event = {
        "event_id": str(uuid.uuid4()), "idempotency_key": "mismatch-test",
        "aggregate_type": "sale", "aggregate_id": str(uuid.uuid4()), "aggregate_version": 1,
        "event_type": "sale.paid", "schema_version": 1, "occurred_at": now,
        "payload_sha256": hashlib.sha256(raw).hexdigest(), "payload": payload,
    }
    batch = {
        "protocol_version": 1, "source_node_id": str(uuid.uuid4()),
        "source_store_id": str(ctx["store_id"]), "worker_id": "test-sender", "events": [event],
    }
    response = ctx["client"].post(
        "/api/v1/sync/events:batch", json=batch,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403
