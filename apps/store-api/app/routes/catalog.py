from fastapi import APIRouter, Depends, Query
from psycopg import Connection

from app.database import get_connection
from app.security import current_cashier

router = APIRouter()


@router.get("/api/v1/catalog/products")
def list_products(
    q: str | None = Query(default=None, max_length=120),
    cashier: dict = Depends(current_cashier),
    connection: Connection = Depends(get_connection),
):
    search = f"%{q.strip()}%" if q and q.strip() else None
    rows = connection.execute(
        """
        SELECT p.id, p.sku, p.name, p.base_uom_code, p.version,
               barcode.barcode, price.price, price.version AS price_version,
               COALESCE(tax.tax_code, 'ZERO') AS tax_code,
               COALESCE(tax.tax_rate, 0)::numeric(7,4) AS tax_rate
        FROM md_products p
        JOIN LATERAL (
            SELECT pp.price, pp.version
            FROM md_product_prices pp
            WHERE pp.product_id = p.id
              AND pp.valid_from <= now()
              AND (pp.valid_until IS NULL OR pp.valid_until > now())
            ORDER BY pp.valid_from DESC, pp.version DESC
            LIMIT 1
        ) price ON true
        LEFT JOIN LATERAL (
            SELECT b.barcode
            FROM md_product_barcodes b
            WHERE b.product_id = p.id AND b.is_active
            ORDER BY b.created_at
            LIMIT 1
        ) barcode ON true
        LEFT JOIN LATERAL (
            SELECT tr.tax_code, tr.tax_rate
            FROM md_product_tax_rules tr
            WHERE tr.product_id = p.id
              AND tr.valid_from <= now()
              AND (tr.valid_until IS NULL OR tr.valid_until > now())
            ORDER BY tr.valid_from DESC, tr.version DESC
            LIMIT 1
        ) tax ON true
        LEFT JOIN md_product_store_availability availability
          ON availability.product_id = p.id AND availability.store_id = %s
        WHERE p.is_active
          AND COALESCE(availability.is_available, true)
          AND (
            %s::text IS NULL OR p.sku ILIKE %s OR p.name ILIKE %s
            OR barcode.barcode ILIKE %s
          )
        ORDER BY p.name, p.sku
        """,
        (cashier["store_id"], search, search, search, search),
    ).fetchall()
    return [
        {
            "id": str(row["id"]),
            "sku": row["sku"],
            "name": row["name"],
            "barcode": row["barcode"],
            "base_uom_code": row["base_uom_code"],
            "price": format(row["price"], ".2f"),
            "price_version": row["price_version"],
            "tax_code": row["tax_code"],
            "tax_rate": format(row["tax_rate"], ".4f"),
        }
        for row in rows
    ]
