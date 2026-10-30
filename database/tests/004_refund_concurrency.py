#!/usr/bin/env python3
"""Two-connection concurrency regression test for refund row locking.

Environment:
  POS_TEST_DSN=postgresql://pos_test:pos_test_password@localhost:5432/pos_test
Requires psycopg 3 (pip install "psycopg[binary]").
Fixture rows remain in the disposable test database for diagnostics.
"""
import os
import threading
import time
import uuid

import psycopg
from psycopg.errors import CheckViolation

DSN = os.environ["POS_TEST_DSN"]
ids = {}
ready = threading.Event()
results = {}

def setup():
    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO pos, public")
            cur.execute("INSERT INTO org_stores(code,name) VALUES (%s,%s) RETURNING id",
                        ("CONCUR-" + uuid.uuid4().hex[:10], "Concurrency Test"))
            ids["store"] = cur.fetchone()[0]
            cur.execute("INSERT INTO iam_users(employee_code,full_name,pin_hash) VALUES (%s,%s,%s) RETURNING id",
                        ("CONCUR-" + uuid.uuid4().hex[:10], "Concurrency Test", "test-only"))
            ids["user"] = cur.fetchone()[0]
            cur.execute("INSERT INTO org_terminals(store_id,code) VALUES (%s,%s) RETURNING id",
                        (ids["store"], "CONCUR-POS"))
            ids["terminal"] = cur.fetchone()[0]
            cur.execute("INSERT INTO md_products(sku,name,base_uom_code) VALUES (%s,%s,%s) RETURNING id",
                        ("CONCUR-" + uuid.uuid4().hex[:10], "Concurrency Product", "PCS"))
            ids["product"] = cur.fetchone()[0]
            cur.execute("SELECT id FROM md_payment_methods WHERE code='CASH'")
            ids["cash"] = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO pos_sales(receipt_number,store_id,terminal_id,cashier_id,business_date,
                                      status,subtotal,grand_total)
                VALUES (%s,%s,%s,%s,CURRENT_DATE,'draft',100000,100000) RETURNING id
            """, ("CONCUR-" + uuid.uuid4().hex, ids["store"], ids["terminal"], ids["user"]))
            ids["sale"] = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO pos_sale_lines(sale_id,product_id,sku_snapshot,name_snapshot,quantity,
                                           unit_price,gross_amount,taxable_base,line_total)
                VALUES (%s,%s,'CONCUR','Concurrency Product',1,100000,100000,100000,100000)
                RETURNING id
            """, (ids["sale"], ids["product"]))
            ids["line"] = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO pos_payments(sale_id,payment_method_id,amount,status,confirmed_at)
                VALUES (%s,%s,100000,'confirmed',now())
            """, (ids["sale"], ids["cash"]))
            cur.execute("UPDATE pos_sales SET status='paid', paid_at=now() WHERE id=%s", (ids["sale"],))
        conn.commit()

def refund_worker(label, sleep_before_commit=0):
    try:
        with psycopg.connect(DSN) as conn:
            with conn.cursor() as cur:
                cur.execute("SET search_path TO pos, public")
                cur.execute("""
                    INSERT INTO pos_refunds(original_sale_id,store_id,terminal_id,processed_by,
                                            refund_method_id,reason,total_amount,status,completed_at)
                    VALUES (%s,%s,%s,%s,%s,%s,100000,'approved',NULL) RETURNING id
                """, (ids["sale"], ids["store"], ids["terminal"], ids["user"], ids["cash"], label))
                refund_id = cur.fetchone()[0]
                cur.execute("""
                    INSERT INTO pos_refund_lines(refund_id,original_sale_line_id,quantity,refund_amount)
                    VALUES (%s,%s,1,100000)
                """, (refund_id, ids["line"]))
                cur.execute("UPDATE pos_refunds SET status='paid', completed_at=now() WHERE id=%s", (refund_id,))
                if label == "first":
                    ready.set()
                    time.sleep(sleep_before_commit)
            conn.commit()
        results[label] = "committed"
    except CheckViolation as exc:
        results[label] = "rejected"
    except Exception as exc:  # surfaced as test failure below
        results[label] = f"error: {type(exc).__name__}: {exc}"

setup()
try:
    first = threading.Thread(target=refund_worker, args=("first", 2))
    first.start()
    if not ready.wait(10):
        raise RuntimeError("First refund did not reach its locked section")
    second = threading.Thread(target=refund_worker, args=("second", 0))
    second.start()
    first.join(15)
    second.join(15)
    if first.is_alive() or second.is_alive():
        raise RuntimeError("Concurrent refund test timed out (possible lock deadlock)")
    if results.get("first") != "committed" or results.get("second") != "rejected":
        raise AssertionError(f"Expected first commit and second rejection; got {results}")
    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO pos, public")
            cur.execute("""
                SELECT COALESCE(sum(rl.quantity),0), COALESCE(sum(rl.refund_amount),0)
                FROM pos_refund_lines rl
                JOIN pos_refunds r ON r.id=rl.refund_id
                WHERE rl.original_sale_line_id=%s AND r.status='paid'
            """, (ids["line"],))
            qty, amount = cur.fetchone()
    if qty != 1 or amount != 100000:
        raise AssertionError(f"Concurrent over-refund escaped guard: qty={qty}, amount={amount}")
    print("CONCURRENCY PASS: competing refunds serialized; only one committed")
finally:
    pass  # Test database is ephemeral; preserve fixtures for failure diagnosis.
