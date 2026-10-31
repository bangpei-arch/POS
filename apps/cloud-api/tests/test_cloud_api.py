import base64
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import psycopg
import pytest
from argon2 import PasswordHasher
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

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
        conn.execute("DELETE FROM cloud.product_prices WHERE product_id=%s", (product_id,))
        conn.execute("DELETE FROM cloud.products WHERE id=%s", (product_id,))
        conn.execute("DELETE FROM cloud.node_credentials WHERE node_id=%s", (node_id,))
        conn.execute("DELETE FROM cloud.sync_nodes WHERE id=%s", (node_id,))
        conn.execute("DELETE FROM cloud.stores WHERE id=%s", (store_id,))
    get_settings.cache_clear()


def token_for(ctx, secret=None):
    client = ctx["client"]
    basic = base64.b64encode(
        f'{ctx["client_id"]}:{secret or ctx["client_secret"]}'.encode()
    ).decode()
    response = client.post(
        "/api/v1/oauth/token",
        data={"grant_type": "client_credentials"},
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
               for p in body["products"])
    assert {m["code"] for m in body["payment_methods"]} >= {"CASH", "TRANSFER", "QRIS"}

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
