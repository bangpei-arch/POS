import os
import sys
import uuid
from pathlib import Path
from decimal import Decimal

import psycopg
import pytest
from argon2 import PasswordHasher
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings
from app.main import app


@pytest.fixture
def store_api(monkeypatch):
    dsn = os.environ["STORE_DATABASE_URL"]
    store_id, node_id, terminal_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    user_id, drawer_id, product_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    store_code = "T" + uuid.uuid4().hex[:8].upper()
    node_code = "N" + uuid.uuid4().hex[:8].upper()
    employee_code = "E" + uuid.uuid4().hex[:8].upper()
    sku = "SKU-" + uuid.uuid4().hex[:8].upper()
    jwt_secret = uuid.uuid4().hex + uuid.uuid4().hex

    monkeypatch.setenv("STORE_DATABASE_URL", dsn)
    monkeypatch.setenv("STORE_ID", str(store_id))
    monkeypatch.setenv("STORE_NODE_ID", str(node_id))
    monkeypatch.setenv("STORE_NODE_CODE", node_code)
    monkeypatch.setenv("TERMINAL_ID", str(terminal_id))
    monkeypatch.setenv("STORE_JWT_SECRET", jwt_secret)
    get_settings.cache_clear()

    with psycopg.connect(dsn) as conn:
        conn.execute("SET search_path TO pos, public")
        conn.execute(
            "INSERT INTO org_stores(id,code,name,timezone,currency_code) VALUES (%s,%s,%s,'Asia/Jakarta','IDR')",
            (store_id, store_code, "Store API Test"),
        )
        conn.execute(
            "INSERT INTO sync_nodes(id,node_type,store_id,node_code,status) VALUES (%s,'store_server',%s,%s,'active')",
            (node_id, store_id, node_code),
        )
        conn.execute(
            "INSERT INTO org_store_servers(store_id,server_code,status) VALUES (%s,%s,'active')",
            (store_id, node_code),
        )
        conn.execute(
            "INSERT INTO iam_users(id,employee_code,full_name,pin_hash) VALUES (%s,%s,'Test Cashier',%s)",
            (user_id, employee_code, PasswordHasher().hash("1234")),
        )
        conn.execute(
            "INSERT INTO org_terminals(id,store_id,code,name,primary_cashier_id) VALUES (%s,%s,'POS01','Test POS',%s)",
            (terminal_id, store_id, user_id),
        )
        conn.execute(
            "INSERT INTO iam_user_store_assignments(user_id,store_id) VALUES (%s,%s)",
            (user_id, store_id),
        )
        cashier_role = conn.execute("SELECT id FROM iam_roles WHERE code='CASHIER'").fetchone()[0]
        conn.execute(
            "INSERT INTO iam_user_role_assignments(user_id,role_id,store_id) VALUES (%s,%s,%s)",
            (user_id, cashier_role, store_id),
        )
        conn.execute(
            "INSERT INTO cash_drawers(id,store_id,terminal_id,fixed_float_amount) VALUES (%s,%s,%s,100000)",
            (drawer_id, store_id, terminal_id),
        )
        conn.execute(
            "INSERT INTO md_products(id,sku,name,base_uom_code) VALUES (%s,%s,'Test Bakery Product','pcs')",
            (product_id, sku),
        )
        conn.execute(
            "INSERT INTO md_product_prices(product_id,price,valid_from,version) VALUES (%s,12500,now()-interval '1 hour',1)",
            (product_id,),
        )
        conn.execute(
            "INSERT INTO md_product_store_availability(product_id,store_id,is_available) VALUES (%s,%s,true)",
            (product_id, store_id),
        )

    with TestClient(app) as client:
        yield {
            "client": client, "dsn": dsn, "store_id": store_id, "node_id": node_id,
            "terminal_id": terminal_id, "user_id": user_id, "drawer_id": drawer_id,
            "product_id": product_id, "employee_code": employee_code, "sku": sku,
        }

    with psycopg.connect(dsn) as conn:
        conn.execute("SET search_path TO pos, public")
        conn.execute("DELETE FROM sync_outbox WHERE node_id=%s", (node_id,))
        conn.execute("DELETE FROM audit_events WHERE store_id=%s", (store_id,))
        conn.execute("DELETE FROM pos_payment_events WHERE payment_id IN (SELECT id FROM pos_payments WHERE sale_id IN (SELECT id FROM pos_sales WHERE store_id=%s))", (store_id,))
        conn.execute("DELETE FROM pos_sale_status_events WHERE sale_id IN (SELECT id FROM pos_sales WHERE store_id=%s)", (store_id,))
        conn.execute("DELETE FROM pos_payments WHERE sale_id IN (SELECT id FROM pos_sales WHERE store_id=%s)", (store_id,))
        conn.execute("DELETE FROM pos_sale_lines WHERE sale_id IN (SELECT id FROM pos_sales WHERE store_id=%s)", (store_id,))
        conn.execute("DELETE FROM pos_sales WHERE store_id=%s", (store_id,))
        conn.execute("DELETE FROM pos_sale_number_sequences WHERE terminal_id=%s", (terminal_id,))
        conn.execute("DELETE FROM cash_session_events WHERE session_id IN (SELECT id FROM cash_sessions WHERE store_id=%s)", (store_id,))
        conn.execute("DELETE FROM cash_sessions WHERE store_id=%s", (store_id,))
        conn.execute("DELETE FROM cash_drawers WHERE id=%s", (drawer_id,))
        conn.execute("DELETE FROM iam_user_role_assignments WHERE user_id=%s", (user_id,))
        conn.execute("DELETE FROM iam_user_store_assignments WHERE user_id=%s", (user_id,))
        conn.execute("DELETE FROM org_terminals WHERE id=%s", (terminal_id,))
        conn.execute("DELETE FROM iam_users WHERE id=%s", (user_id,))
        conn.execute("DELETE FROM org_store_servers WHERE server_code=(SELECT node_code FROM sync_nodes WHERE id=%s)", (node_id,))
        conn.execute("DELETE FROM sync_nodes WHERE id=%s", (node_id,))
        conn.execute("DELETE FROM md_product_store_availability WHERE product_id=%s", (product_id,))
        conn.execute("DELETE FROM md_product_prices WHERE product_id=%s", (product_id,))
        conn.execute("DELETE FROM md_products WHERE id=%s", (product_id,))
        conn.execute("DELETE FROM org_stores WHERE id=%s", (store_id,))
    get_settings.cache_clear()


def test_one_paid_sale_and_idempotent_retry(store_api):
    ctx = store_api
    client = ctx["client"]

    login = client.post(
        "/api/v1/auth/login",
        json={"employee_code": ctx["employee_code"], "pin": "1234"},
    )
    assert login.status_code == 200
    token = login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    catalog = client.get("/api/v1/catalog/products", headers=headers)
    assert catalog.status_code == 200
    assert any(item["id"] == str(ctx["product_id"]) for item in catalog.json())

    opened = client.post(
        "/api/v1/sessions/open",
        json={"opening_counted": "100000.00"},
        headers=headers,
    )
    assert opened.status_code == 200
    session_id = opened.json()["session_id"]

    request_body = {
        "lines": [{"product_id": str(ctx["product_id"]), "quantity": 1}],
        "payment_method_code": "CASH",
        "cash_received_amount": "20000.00",
    }
    sale_headers = {**headers, "Idempotency-Key": "mvp-sale-test-001"}
    sale = client.post("/api/v1/sales", json=request_body, headers=sale_headers)
    assert sale.status_code == 200
    data = sale.json()
    assert data["status"] == "paid"
    assert data["grand_total"] == "12500.00"
    assert data["change_amount"] == "7500.00"
    assert data["idempotent_replay"] is False

    retry = client.post("/api/v1/sales", json=request_body, headers=sale_headers)
    assert retry.status_code == 200
    assert retry.json()["sale_id"] == data["sale_id"]
    assert retry.json()["idempotent_replay"] is True

    changed_body = {
        "lines": [{"product_id": str(ctx["product_id"]), "quantity": 2}],
        "payment_method_code": "CASH",
        "cash_received_amount": "30000.00",
    }
    conflict = client.post("/api/v1/sales", json=changed_body, headers=sale_headers)
    assert conflict.status_code == 409

    closed = client.post(
        f"/api/v1/sessions/{session_id}/close",
        json={"closing_counted": "112500.00"},
        headers=headers,
    )
    assert closed.status_code == 200
    assert closed.json()["expected_cash"] == "112500.00"
    assert closed.json()["variance_amount"] == "0.00"

    with psycopg.connect(ctx["dsn"]) as conn:
        sale_row = conn.execute(
            "SELECT status, cash_session_id, grand_total FROM pos_sales WHERE id=%s",
            (uuid.UUID(data["sale_id"]),),
        ).fetchone()
        assert sale_row[0] == "paid"
        assert sale_row[1] == uuid.UUID(session_id)
        assert sale_row[2] == Decimal("12500.00")
        outbox = conn.execute(
            "SELECT count(*) FROM sync_outbox WHERE aggregate_id=%s AND event_type='sale.paid'",
            (uuid.UUID(data["sale_id"]),),
        ).fetchone()[0]
        assert outbox == 1
        audit_outbox = conn.execute(
            "SELECT count(*) FROM sync_outbox WHERE event_type='audit.recorded' AND node_id=%s",
            (ctx["node_id"],),
        ).fetchone()[0]
        assert audit_outbox >= 4
