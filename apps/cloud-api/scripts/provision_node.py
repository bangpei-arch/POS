#!/usr/bin/env python3
"""Provision one store and its store-server OAuth client. Secret is printed once only."""
import argparse
import json
import os
import secrets
import uuid

import psycopg
from argon2 import PasswordHasher

SCOPES = ["sync:events:write", "sync:master:read", "sync:heartbeat:write"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store-code", required=True)
    parser.add_argument("--store-name", required=True)
    parser.add_argument("--node-code", required=True)
    parser.add_argument("--timezone", default="Asia/Jakarta")
    parser.add_argument("--currency", default="IDR")
    args = parser.parse_args()

    dsn = os.environ.get("CLOUD_DATABASE_URL")
    if not dsn:
        raise SystemExit("CLOUD_DATABASE_URL is required")

    store_id = uuid.uuid4()
    node_id = uuid.uuid4()
    client_id = f"pos-{args.node_code.lower()}"
    client_secret = secrets.token_urlsafe(48)
    secret_hash = PasswordHasher().hash(client_secret)

    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO cloud.stores(id, store_code, store_name, timezone, currency_code)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id
                """,
                (store_id, args.store_code, args.store_name, args.timezone, args.currency),
            )
            cur.execute(
                """
                INSERT INTO cloud.sync_nodes(id, store_id, node_code, node_type, status)
                VALUES (%s, %s, %s, 'store_server', 'active')
                """,
                (node_id, store_id, args.node_code),
            )
            cur.execute(
                """
                INSERT INTO cloud.node_credentials(node_id, client_id, client_secret_hash, scopes)
                VALUES (%s, %s, %s, %s)
                """,
                (node_id, client_id, secret_hash, SCOPES),
            )

    print(json.dumps({
        "store_id": str(store_id),
        "node_id": str(node_id),
        "client_id": client_id,
        "client_secret": client_secret,
        "scopes": SCOPES,
        "warning": "Secret ditampilkan satu kali. Simpan di secret store server toko; jangan commit atau kirim lewat chat.",
    }, indent=2))


if __name__ == "__main__":
    main()
