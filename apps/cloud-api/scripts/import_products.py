#!/usr/bin/env python3
"""Import/upsert the MVP product master from CSV; price changes are versioned."""
import argparse
import csv
import os
import uuid
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

import psycopg


def money(value: str) -> Decimal:
    try:
        result = Decimal(value).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    except InvalidOperation as exc:
        raise ValueError(f"Invalid price: {value}") from exc
    if result < 0:
        raise ValueError("Price cannot be negative")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file")
    args = parser.parse_args()
    dsn = os.environ.get("CLOUD_DATABASE_URL")
    if not dsn:
        raise SystemExit("CLOUD_DATABASE_URL is required")

    count = 0
    with open(args.csv_file, newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source)
        required = {"id", "sku", "name", "price"}
        if not reader.fieldnames or not required.issubset(set(reader.fieldnames)):
            raise SystemExit("CSV columns required: id,sku,name,price; optional: barcode")

        with psycopg.connect(dsn) as conn:
            with conn.cursor() as cur:
                for row in reader:
                    product_id = uuid.UUID(row["id"])
                    price = money(row["price"])
                    cur.execute(
                        """
                        INSERT INTO cloud.products(id, sku, product_name, barcode, tax_code, tax_rate, is_active, updated_at)
                        VALUES (%s, %s, %s, %s, %s, %s, true, now())
                        ON CONFLICT (id) DO UPDATE
                        SET sku = EXCLUDED.sku,
                            product_name = EXCLUDED.product_name,
                            barcode = EXCLUDED.barcode,
                            tax_code = EXCLUDED.tax_code,
                            tax_rate = EXCLUDED.tax_rate,
                            is_active = true,
                            updated_at = now()
                        """,
                        (product_id, row["sku"].strip(), row["name"].strip(), (row.get("barcode") or "").strip() or None,
                         (row.get("tax_code") or "").strip() or None,
                         Decimal(row.get("tax_rate") or "0").quantize(Decimal("0.0001"))),
                    )
                    cur.execute("SELECT id FROM cloud.products WHERE id = %s FOR UPDATE", (product_id,))
                    cur.execute(
                        """
                        SELECT price FROM cloud.product_prices
                        WHERE product_id = %s
                          AND valid_from <= now()
                          AND (valid_until IS NULL OR valid_until > now())
                        ORDER BY valid_from DESC, version DESC
                        LIMIT 1
                        """,
                        (product_id,),
                    )
                    active = cur.fetchone()
                    if active is None or active[0] != price:
                        cur.execute(
                            """
                            UPDATE cloud.product_prices
                            SET valid_until = now(), updated_at = now()
                            WHERE product_id = %s AND valid_until IS NULL
                            """,
                            (product_id,),
                        )
                        cur.execute(
                            "SELECT COALESCE(max(version), 0) + 1 FROM cloud.product_prices WHERE product_id = %s",
                            (product_id,),
                        )
                        next_version = cur.fetchone()[0]
                        cur.execute(
                            """
                            INSERT INTO cloud.product_prices(product_id, price, valid_from, version)
                            VALUES (%s, %s, now(), %s)
                            """,
                            (product_id, price, next_version),
                        )
                    count += 1
    print(f"Imported {count} products; unchanged prices were not versioned again.")


if __name__ == "__main__":
    main()
