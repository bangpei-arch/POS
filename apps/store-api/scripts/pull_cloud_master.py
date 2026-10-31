#!/usr/bin/env python3
"""Fetch the cloud master snapshot and apply it to this store's local PostgreSQL DB."""
import os
from decimal import Decimal
from uuid import UUID

import httpx
import psycopg


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def main() -> None:
    cloud_url = required("CLOUD_API_BASE_URL").rstrip("/")
    client_id = required("CLOUD_CLIENT_ID")
    client_secret = required("CLOUD_CLIENT_SECRET")
    dsn = required("STORE_DATABASE_URL")
    store_id = UUID(required("STORE_ID"))
    node_id = UUID(required("STORE_NODE_ID"))
    node_code = required("STORE_NODE_CODE")

    with httpx.Client(timeout=30.0) as client:
        token_response = client.post(
            f"{cloud_url}/api/v1/oauth/token",
            data={"grant_type": "client_credentials", "scope": "sync:master:read"},
            auth=(client_id, client_secret),
        )
        token_response.raise_for_status()
        token = token_response.json()["access_token"]
        response = client.get(
            f"{cloud_url}/api/v1/sync/master/bootstrap",
            headers={"Authorization": f"Bearer {token}"},
        )
        response.raise_for_status()
        master = response.json()

    if UUID(master["store"]["id"]) != store_id:
        raise SystemExit("Cloud bootstrap store_id does not match STORE_ID")

    products = master["products"]
    methods = master["payment_methods"]

    with psycopg.connect(dsn) as conn:
        conn.execute("SET search_path TO pos, public")
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO org_stores(id,code,name,timezone,currency_code,is_active,updated_at)
                VALUES (%s,%s,%s,%s,%s,true,now())
                ON CONFLICT (id) DO UPDATE SET
                    code=EXCLUDED.code, name=EXCLUDED.name, timezone=EXCLUDED.timezone,
                    currency_code=EXCLUDED.currency_code, is_active=true, updated_at=now()
                """,
                (store_id, master["store"]["store_code"], master["store"]["store_name"],
                 master["store"]["timezone"], master["store"]["currency_code"]),
            )
            cur.execute(
                """
                INSERT INTO sync_nodes(id,node_type,store_id,node_code,status)
                VALUES (%s,'store_server',%s,%s,'active')
                ON CONFLICT (id) DO UPDATE SET
                    node_type='store_server',store_id=EXCLUDED.store_id,
                    node_code=EXCLUDED.node_code,status='active'
                """,
                (node_id, store_id, node_code),
            )
            cur.execute(
                """
                INSERT INTO org_store_servers(store_id,server_code,status,last_seen_at)
                VALUES (%s,%s,'active',now())
                ON CONFLICT (server_code) DO UPDATE SET
                    store_id=EXCLUDED.store_id,status='active',last_seen_at=now()
                """,
                (store_id, node_code),
            )

            # Full snapshot: hide stale local products and methods before reactivating returned rows.
            cur.execute("UPDATE md_products SET is_active=false,updated_at=now()")
            cur.execute("UPDATE md_product_barcodes SET is_active=false WHERE is_active")
            cur.execute("UPDATE md_payment_methods SET is_active=false")

            for product in products:
                product_id = UUID(product["id"])
                product_version = int(product["product_version"])
                cur.execute(
                    """
                    INSERT INTO md_products(id,sku,name,base_uom_code,is_active,version,updated_at)
                    VALUES (%s,%s,%s,%s,true,%s,now())
                    ON CONFLICT (id) DO UPDATE SET
                        sku=EXCLUDED.sku,name=EXCLUDED.name,base_uom_code=EXCLUDED.base_uom_code,
                        is_active=true,version=EXCLUDED.version,updated_at=now()
                    """,
                    (product_id, product["sku"], product["name"], product["base_uom_code"], product_version),
                )

                barcode = product.get("barcode")
                if barcode:
                    existing = cur.execute(
                        "SELECT product_id FROM md_product_barcodes WHERE barcode=%s AND is_active",
                        (barcode,),
                    ).fetchone()
                    if existing and existing[0] != product_id:
                        raise RuntimeError(f"Active barcode {barcode} belongs to another local product")
                    cur.execute(
                        "UPDATE md_product_barcodes SET is_active=true WHERE product_id=%s AND barcode=%s",
                        (product_id, barcode),
                    )
                    cur.execute(
                        """
                        INSERT INTO md_product_barcodes(product_id,barcode,is_active)
                        SELECT %s,%s,true
                        WHERE NOT EXISTS (
                            SELECT 1 FROM md_product_barcodes WHERE product_id=%s AND barcode=%s
                        )
                        """,
                        (product_id, barcode, product_id, barcode),
                    )

                price_version = int(product["price_version"])
                cur.execute(
                    """
                    UPDATE md_product_prices SET valid_until=now()
                    WHERE product_id=%s AND valid_until IS NULL AND version<>%s
                    """,
                    (product_id, price_version),
                )
                cur.execute(
                    """
                    INSERT INTO md_product_prices(product_id,price,valid_from,version)
                    VALUES (%s,%s,now(),%s)
                    ON CONFLICT (product_id,version) DO UPDATE SET price=EXCLUDED.price
                    """,
                    (product_id, Decimal(product["price"]), price_version),
                )

                tax_code = product.get("tax_code")
                tax_rate = Decimal(product.get("tax_rate") or "0")
                if tax_rate > 0 and not tax_code:
                    raise RuntimeError(f"Product {product['sku']} has a tax rate but no tax code")
                if tax_code:
                    cur.execute(
                        """
                        UPDATE md_product_tax_rules SET valid_until=now()
                        WHERE product_id=%s AND valid_until IS NULL AND version<>%s
                        """,
                        (product_id, product_version),
                    )
                    cur.execute(
                        """
                        INSERT INTO md_product_tax_rules(product_id,tax_code,tax_rate,valid_from,version)
                        VALUES (%s,%s,%s,now(),%s)
                        ON CONFLICT (product_id,tax_code,version) DO UPDATE SET tax_rate=EXCLUDED.tax_rate
                        """,
                        (product_id, tax_code, tax_rate, product_version),
                    )
                else:
                    cur.execute(
                        "UPDATE md_product_tax_rules SET valid_until=now() WHERE product_id=%s AND valid_until IS NULL",
                        (product_id,),
                    )

                cur.execute(
                    """
                    INSERT INTO md_product_store_availability(product_id,store_id,is_available,updated_at)
                    VALUES (%s,%s,true,now())
                    ON CONFLICT (product_id,store_id) DO UPDATE
                    SET is_available=true,reason=NULL,updated_at=now()
                    """,
                    (product_id, store_id),
                )

            for method in methods:
                cur.execute(
                    """
                    INSERT INTO md_payment_methods(
                        code,name,method_type,requires_reference,is_cash,is_active,version
                    ) VALUES (%s,%s,%s,%s,%s,true,%s)
                    ON CONFLICT (code) DO UPDATE SET
                        name=EXCLUDED.name,method_type=EXCLUDED.method_type,
                        requires_reference=EXCLUDED.requires_reference,is_cash=EXCLUDED.is_cash,
                        is_active=true,version=EXCLUDED.version
                    """,
                    (
                        method["code"], method["display_name"], method["method_type"],
                        method["requires_reference"], method["is_cash"], method["version"],
                    ),
                )

    print(
        f"Master bootstrap applied: store={store_id}, node={node_id}, "
        f"products={len(products)}, payment_methods={len(methods)}, "
        f"master_version={master['master_version']}"
    )


if __name__ == "__main__":
    main()
