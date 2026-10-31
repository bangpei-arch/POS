import hashlib
import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from psycopg import Connection
from psycopg.types.json import Jsonb

from app.audit import record_audit
from app.config import get_settings
from app.database import get_connection
from app.security import current_cashier

router = APIRouter()
CENT = Decimal("0.01")


class SaleLineInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    product_id: uuid.UUID
    quantity: int = Field(gt=0, le=10000)


class CreateSaleInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    lines: list[SaleLineInput] = Field(min_length=1, max_length=200)
    payment_method_code: str = Field(min_length=1, max_length=30)
    cash_received_amount: Decimal | None = None
    reference_number: str | None = Field(default=None, max_length=120)


def _money(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def _sale_response(connection: Connection, sale_id: uuid.UUID, replay: bool) -> dict:
    sale = connection.execute(
        """
        SELECT id, receipt_number, status, grand_total, currency_code, paid_at
        FROM pos_sales WHERE id=%s
        """,
        (sale_id,),
    ).fetchone()
    payment = connection.execute(
        """
        SELECT amount, cash_received_amount, change_amount, reference_number
        FROM pos_payments WHERE sale_id=%s ORDER BY created_at LIMIT 1
        """,
        (sale_id,),
    ).fetchone()
    return {
        "sale_id": str(sale["id"]),
        "receipt_number": sale["receipt_number"],
        "status": sale["status"],
        "grand_total": format(sale["grand_total"], ".2f"),
        "currency_code": sale["currency_code"],
        "paid_at": sale["paid_at"].isoformat() if sale["paid_at"] else None,
        "cash_received_amount": format(payment["cash_received_amount"], ".2f")
            if payment and payment["cash_received_amount"] is not None else None,
        "change_amount": format(payment["change_amount"], ".2f") if payment else "0.00",
        "reference_number": payment["reference_number"] if payment else None,
        "idempotent_replay": replay,
    }


@router.post("/api/v1/sales")
def create_sale(
    body: CreateSaleInput,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    cashier: dict = Depends(current_cashier),
    connection: Connection = Depends(get_connection),
):
    settings = get_settings()
    if not idempotency_key or not idempotency_key.strip() or len(idempotency_key) > 140:
        raise HTTPException(status_code=400, detail="Idempotency-Key header is required (max 140 chars)")

    canonical_body = json.dumps(
        body.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    request_hash = hashlib.sha256(canonical_body).digest()

    with connection.transaction():
        # Serialize requests sharing the same key, including simultaneous terminal retries.
        connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f'{settings.store_id}:{idempotency_key}',),
        )
        existing = connection.execute(
            """
            SELECT id, idempotency_hash
            FROM pos_sales
            WHERE store_id=%s AND idempotency_key=%s
            """,
            (settings.store_id, idempotency_key),
        ).fetchone()
        if existing:
            if bytes(existing["idempotency_hash"]) != request_hash:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request body",
                )
            return _sale_response(connection, existing["id"], replay=True)

        session = connection.execute(
            """
            SELECT id FROM cash_sessions
            WHERE store_id=%s AND terminal_id=%s AND cashier_id=%s AND status='open'
            ORDER BY opened_at DESC LIMIT 1 FOR UPDATE
            """,
            (settings.store_id, settings.terminal_id, cashier["user_id"]),
        ).fetchone()
        if not session:
            raise HTTPException(status_code=409, detail="Open cash session is required")

        store = connection.execute(
            """
            SELECT s.code, s.currency_code, s.timezone, t.code AS terminal_code
            FROM org_stores s
            JOIN org_terminals t ON t.store_id=s.id
            WHERE s.id=%s AND t.id=%s AND s.is_active AND t.is_active
            """,
            (settings.store_id, settings.terminal_id),
        ).fetchone()
        if not store:
            raise HTTPException(status_code=409, detail="Store or terminal is inactive")

        lines: list[dict] = []
        subtotal = Decimal("0.00")
        for requested in body.lines:
            product = connection.execute(
                """
                SELECT p.id, p.sku, p.name, barcode.barcode,
                       price.price, price.version AS price_version,
                       COALESCE(tax.tax_code, 'ZERO') AS tax_code,
                       COALESCE(tax.tax_rate, 0)::numeric(7,4) AS tax_rate
                FROM md_products p
                JOIN LATERAL (
                    SELECT pp.price, pp.version
                    FROM md_product_prices pp
                    WHERE pp.product_id=p.id AND pp.valid_from <= now()
                      AND (pp.valid_until IS NULL OR pp.valid_until > now())
                    ORDER BY pp.valid_from DESC, pp.version DESC LIMIT 1
                ) price ON true
                LEFT JOIN LATERAL (
                    SELECT b.barcode FROM md_product_barcodes b
                    WHERE b.product_id=p.id AND b.is_active
                    ORDER BY b.created_at LIMIT 1
                ) barcode ON true
                LEFT JOIN LATERAL (
                    SELECT tr.tax_code, tr.tax_rate
                    FROM md_product_tax_rules tr
                    WHERE tr.product_id=p.id AND tr.valid_from <= now()
                      AND (tr.valid_until IS NULL OR tr.valid_until > now())
                    ORDER BY tr.valid_from DESC, tr.version DESC LIMIT 1
                ) tax ON true
                LEFT JOIN md_product_store_availability availability
                  ON availability.product_id=p.id AND availability.store_id=%s
                WHERE p.id=%s AND p.is_active
                  AND COALESCE(availability.is_available, true)
                """,
                (settings.store_id, requested.product_id),
            ).fetchone()
            if not product:
                raise HTTPException(status_code=409, detail=f"Product {requested.product_id} is unavailable or has no active price")
            tax_rate = product["tax_rate"]
            if tax_rate != 0:
                raise HTTPException(
                    status_code=422,
                    detail="MVP sale calculation currently accepts zero-tax products only; tax-inclusive/exclusive mode must be configured before taxable products are sold",
                )
            gross = _money(product["price"] * requested.quantity)
            lines.append({
                "line_id": uuid.uuid4(),
                "product_id": product["id"],
                "sku": product["sku"],
                "name": product["name"],
                "barcode": product["barcode"],
                "quantity": requested.quantity,
                "unit_price": product["price"],
                "gross_amount": gross,
                "discount_amount": Decimal("0.00"),
                "tax_code": product["tax_code"],
                "tax_rate": tax_rate,
                "tax_amount": Decimal("0.00"),
                "line_total": gross,
                "price_version": product["price_version"],
            })
            subtotal += gross

        subtotal = _money(subtotal)
        grand_total = subtotal
        method = connection.execute(
            """
            SELECT id, code, name, is_cash, requires_reference, is_active
            FROM md_payment_methods WHERE code=%s AND is_active
            """,
            (body.payment_method_code.upper(),),
        ).fetchone()
        if not method or method["code"] not in {"CASH", "TRANSFER", "QRIS"}:
            raise HTTPException(status_code=422, detail="MVP supports CASH, TRANSFER, and QRIS only")

        if method["is_cash"]:
            if body.reference_number:
                raise HTTPException(status_code=422, detail="Cash payment must not include a transfer reference")
            if body.cash_received_amount is None or body.cash_received_amount < grand_total:
                raise HTTPException(status_code=422, detail="Cash received must be at least the grand total")
            cash_received = _money(body.cash_received_amount)
            change_amount = _money(cash_received - grand_total)
        else:
            if body.cash_received_amount is not None:
                raise HTTPException(status_code=422, detail="Non-cash payment must not include cash received")
            if method["requires_reference"] and not (body.reference_number or "").strip():
                raise HTTPException(status_code=422, detail="Payment reference is required")
            cash_received = None
            change_amount = Decimal("0.00")

        business_date = datetime.now(ZoneInfo(store["timezone"])).date()
        sequence = connection.execute(
            """
            INSERT INTO pos_sale_number_sequences(terminal_id,business_date,next_number)
            VALUES (%s,%s,2)
            ON CONFLICT (terminal_id,business_date)
            DO UPDATE SET next_number=pos_sale_number_sequences.next_number+1,
                          updated_at=now()
            RETURNING next_number - 1 AS allocated
            """,
            (settings.terminal_id, business_date),
        ).fetchone()["allocated"]
        receipt_number = (
            f'{store["code"]}-{business_date:%Y%m%d}-{store["terminal_code"]}-{int(sequence):06d}'
        )

        sale_id = uuid.uuid4()
        paid_at = datetime.now(timezone.utc)
        connection.execute(
            """
            INSERT INTO pos_sales(
                id, receipt_number, store_id, terminal_id, cashier_id, business_date,
                status, currency_code, subtotal, discount_total, tax_total,
                rounding_amount, grand_total, created_at, cash_session_id,
                idempotency_key, idempotency_hash
            ) VALUES (
                %s,%s,%s,%s,%s,%s,'draft',%s,%s,0,0,0,%s,now(),%s,%s,%s
            )
            """,
            (
                sale_id, receipt_number, settings.store_id, settings.terminal_id,
                cashier["user_id"], business_date, store["currency_code"],
                subtotal, grand_total, session["id"], idempotency_key, request_hash,
            ),
        )

        line_payload = []
        for line in lines:
            connection.execute(
                """
                INSERT INTO pos_sale_lines(
                    id, sale_id, product_id, sku_snapshot, name_snapshot, barcode_snapshot,
                    quantity, unit_price, gross_amount, discount_amount, taxable_base,
                    tax_code_snapshot, tax_rate_snapshot, tax_amount, line_total, price_version
                ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    line["line_id"], sale_id, line["product_id"], line["sku"], line["name"],
                    line["barcode"], line["quantity"], line["unit_price"], line["gross_amount"],
                    line["discount_amount"], line["gross_amount"], line["tax_code"],
                    line["tax_rate"], line["tax_amount"], line["line_total"], line["price_version"],
                ),
            )
            line_payload.append({
                "line_id": str(line["line_id"]),
                "product_id": str(line["product_id"]),
                "sku": line["sku"],
                "name": line["name"],
                "barcode": line["barcode"],
                "quantity": line["quantity"],
                "unit_price": format(line["unit_price"], ".2f"),
                "gross_amount": format(line["gross_amount"], ".2f"),
                "discount_amount": "0.00",
                "tax_code": line["tax_code"],
                "tax_rate": format(line["tax_rate"], ".4f"),
                "tax_amount": "0.00",
                "line_total": format(line["line_total"], ".2f"),
            })

        payment_id = uuid.uuid4()
        connection.execute(
            """
            INSERT INTO pos_payments(
                id, sale_id, payment_method_id, amount, status, reference_number,
                confirmed_by, confirmed_at, cash_received_amount, change_amount
            ) VALUES (%s,%s,%s,%s,'confirmed',%s,%s,%s,%s,%s)
            """,
            (
                payment_id, sale_id, method["id"], grand_total,
                (body.reference_number or "").strip() or None,
                cashier["user_id"], paid_at, cash_received, change_amount,
            ),
        )
        connection.execute(
            """
            INSERT INTO pos_payment_events(payment_id,old_status,new_status,actor_id,occurred_at)
            VALUES (%s,'pending','confirmed',%s,%s)
            """,
            (payment_id, cashier["user_id"], paid_at),
        )

        connection.execute(
            "UPDATE pos_sales SET status='paid', paid_at=%s WHERE id=%s",
            (paid_at, sale_id),
        )
        connection.execute(
            """
            INSERT INTO pos_sale_status_events(sale_id,old_status,new_status,actor_id,occurred_at)
            VALUES (%s,'draft','paid',%s,%s)
            """,
            (sale_id, cashier["user_id"], paid_at),
        )

        payment_payload = [{
            "payment_id": str(payment_id),
            "method_code": method["code"],
            "method_name": method["name"],
            "amount": format(grand_total, ".2f"),
            "reference_number": (body.reference_number or "").strip() or None,
            "confirmed_at": paid_at.isoformat(),
        }]
        sale_payload = {
            "sale": {
                "sale_id": str(sale_id),
                "terminal_id": str(settings.terminal_id),
                "cashier_id": cashier["user_id"],
                "receipt_number": receipt_number,
                "business_date": business_date.isoformat(),
                "currency_code": store["currency_code"],
                "subtotal": format(subtotal, ".2f"),
                "discount_total": "0.00",
                "tax_total": "0.00",
                "rounding_amount": "0.00",
                "grand_total": format(grand_total, ".2f"),
                "paid_at": paid_at.isoformat(),
            },
            "lines": line_payload,
            "payments": payment_payload,
        }
        connection.execute(
            """
            INSERT INTO sync_outbox(
                node_id,event_id,aggregate_type,aggregate_id,event_type,payload,schema_version,occurred_at
            ) VALUES (%s,%s,'sale',%s,'sale.paid',%s,1,%s)
            """,
            (
                settings.store_node_id, uuid.uuid4(), sale_id,
                Jsonb(sale_payload), paid_at,
            ),
        )

        record_audit(
            connection, action="sale.payment_confirmed", entity_type="sale",
            entity_id=sale_id, actor_id=uuid.UUID(cashier["user_id"]),
            correlation_id=sale_id,
        )
        record_audit(
            connection, action="sale.paid", entity_type="sale",
            entity_id=sale_id, actor_id=uuid.UUID(cashier["user_id"]),
            correlation_id=sale_id,
        )

    return _sale_response(connection, sale_id, replay=False)
