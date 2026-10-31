#!/usr/bin/env python3
"""Create one local terminal, cashier PIN, store assignment, and cash drawer."""
import argparse
import getpass
import os
import uuid
from decimal import Decimal

import psycopg
from argon2 import PasswordHasher


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--terminal-code", required=True)
    parser.add_argument("--terminal-name", required=True)
    parser.add_argument("--employee-code", required=True)
    parser.add_argument("--cashier-name", required=True)
    parser.add_argument("--fixed-float", default="0")
    args = parser.parse_args()

    dsn = os.environ.get("STORE_DATABASE_URL")
    store_id = os.environ.get("STORE_ID")
    if not dsn or not store_id:
        raise SystemExit("STORE_DATABASE_URL and STORE_ID are required")

    pin = getpass.getpass("Cashier PIN (4-12 digits): ")
    confirm = getpass.getpass("Confirm PIN: ")
    if pin != confirm or not pin.isdigit() or not 4 <= len(pin) <= 12:
        raise SystemExit("PIN must match and contain 4-12 digits")
    fixed_float = Decimal(args.fixed_float)
    if fixed_float < 0:
        raise SystemExit("Fixed float cannot be negative")

    terminal_id = uuid.uuid4()
    user_id = uuid.uuid4()
    drawer_id = uuid.uuid4()
    pin_hash = PasswordHasher().hash(pin)

    with psycopg.connect(dsn) as conn:
        conn.execute("SET search_path TO pos, public")
        with conn.cursor() as cur:
            role = cur.execute("SELECT id FROM iam_roles WHERE code='CASHIER'").fetchone()
            if not role:
                raise SystemExit("CASHIER role is missing; apply local migrations first")
            cur.execute(
                """
                INSERT INTO iam_users(id,employee_code,full_name,pin_hash,status)
                VALUES (%s,%s,%s,%s,'active')
                """,
                (user_id, args.employee_code, args.cashier_name, pin_hash),
            )
            cur.execute(
                """
                INSERT INTO org_terminals(id,store_id,code,name,primary_cashier_id,is_active)
                VALUES (%s,%s,%s,%s,%s,true)
                """,
                (terminal_id, store_id, args.terminal_code, args.terminal_name, user_id),
            )
            cur.execute(
                "INSERT INTO iam_user_store_assignments(user_id,store_id) VALUES (%s,%s)",
                (user_id, store_id),
            )
            cur.execute(
                """
                INSERT INTO iam_user_role_assignments(user_id,role_id,store_id)
                VALUES (%s,%s,%s)
                """,
                (user_id, role[0], store_id),
            )
            cur.execute(
                """
                INSERT INTO cash_drawers(id,store_id,terminal_id,fixed_float_amount)
                VALUES (%s,%s,%s,%s)
                """,
                (drawer_id, store_id, terminal_id, fixed_float),
            )

    print(f"TERMINAL_ID={terminal_id}")
    print(f"CASHIER_ID={user_id}")
    print(f"CASH_DRAWER_ID={drawer_id}")
    print("Set TERMINAL_ID in the store API .env file. The PIN hash is stored locally; PIN is not printed.")


if __name__ == "__main__":
    main()
