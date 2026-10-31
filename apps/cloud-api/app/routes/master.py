from fastapi import APIRouter, Depends
from psycopg import Connection

from app.database import get_connection
from app.security import require_scope

router = APIRouter()


@router.get("/api/v1/sync/master/bootstrap")
def master_bootstrap(
    node: dict = Depends(require_scope("sync:master:read")),
    connection: Connection = Depends(get_connection),
):
    store = connection.execute(
        """
        SELECT id, store_code, store_name, timezone, currency_code
        FROM cloud.stores
        WHERE id = %s AND is_active
        """,
        (node["store_id"],),
    ).fetchone()
    if not store:
        from fastapi import HTTPException
        raise HTTPException(status_code=403, detail="Store is inactive or unavailable")

    products = connection.execute(
        """
        SELECT p.id, p.sku, p.product_name, p.barcode,
               price.price, price.version AS price_version
        FROM cloud.products p
        JOIN LATERAL (
            SELECT pp.price, pp.version
            FROM cloud.product_prices pp
            WHERE pp.product_id = p.id
              AND pp.valid_from <= now()
              AND (pp.valid_until IS NULL OR pp.valid_until > now())
            ORDER BY pp.valid_from DESC, pp.version DESC
            LIMIT 1
        ) price ON true
        WHERE p.is_active
        ORDER BY p.sku
        """
    ).fetchall()

    methods = connection.execute(
        """
        SELECT code, display_name, requires_manual_confirmation
        FROM cloud.payment_methods
        WHERE is_active
        ORDER BY code
        """
    ).fetchall()

    version_row = connection.execute(
        """
        SELECT GREATEST(
            COALESCE((SELECT max(updated_at) FROM cloud.products), '-infinity'::timestamptz),
            COALESCE((SELECT max(updated_at) FROM cloud.product_prices), '-infinity'::timestamptz),
            COALESCE((SELECT max(updated_at) FROM cloud.payment_methods), '-infinity'::timestamptz)
        ) AS master_version
        """
    ).fetchone()

    return {
        "store": {**store, "id": str(store["id"])},
        "master_version": version_row["master_version"].isoformat(),
        "products": [
            {
                "id": str(p["id"]),
                "sku": p["sku"],
                "name": p["product_name"],
                "barcode": p["barcode"],
                "price": format(p["price"], ".2f"),
                "price_version": p["price_version"],
            }
            for p in products
        ],
        "payment_methods": methods,
    }
