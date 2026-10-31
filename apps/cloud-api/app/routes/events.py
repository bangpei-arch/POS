import hashlib
import json
import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from psycopg import Connection
from psycopg.types.json import Jsonb

from app.database import get_connection
from app.security import require_scope

router = APIRouter()


class EventInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    event_id: uuid.UUID
    idempotency_key: str = Field(min_length=1, max_length=140)
    aggregate_type: str = Field(min_length=1, max_length=60)
    aggregate_id: uuid.UUID
    aggregate_version: int = Field(gt=0)
    event_type: str = Field(min_length=1, max_length=80)
    schema_version: int = Field(default=1, gt=0)
    occurred_at: datetime
    payload_sha256: str = Field(pattern=r"^[0-9a-fA-F]{64}$")
    payload: dict


class EventBatchInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    protocol_version: int = Field(ge=1, le=1)
    source_node_id: uuid.UUID
    source_store_id: uuid.UUID
    worker_id: str = Field(min_length=1, max_length=120)
    events: list[EventInput] = Field(min_length=1, max_length=25)


def _canonical_hash(payload: dict) -> bytes:
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(raw).digest()


def _decimal(value, field: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        raise HTTPException(status_code=422, detail=f"Invalid decimal field: {field}") from None
    if not result.is_finite():
        raise HTTPException(status_code=422, detail=f"Invalid decimal field: {field}")
    return result


def _process_sale(connection: Connection, node: dict, event: EventInput) -> None:
    payload = event.payload
    if event.event_type != "sale.paid" or event.aggregate_type != "sale":
        raise HTTPException(status_code=422, detail="MVP receiver accepts sale.paid events only")
    sale = payload.get("sale")
    lines = payload.get("lines")
    payments = payload.get("payments")
    if not isinstance(sale, dict) or not isinstance(lines, list) or not isinstance(payments, list):
        raise HTTPException(status_code=422, detail="sale.paid payload requires sale, lines, and payments")
    if uuid.UUID(str(sale.get("sale_id"))) != event.aggregate_id:
        raise HTTPException(status_code=422, detail="aggregate_id must match payload sale_id")
    if not lines or not payments:
        raise HTTPException(status_code=422, detail="Paid sale requires lines and confirmed payments")

    grand_total = _decimal(sale.get("grand_total"), "grand_total")
    line_total = sum((_decimal(line.get("line_total"), "line_total") for line in lines), Decimal("0"))
    payment_total = sum((_decimal(payment.get("amount"), "payment.amount") for payment in payments), Decimal("0"))
    if grand_total <= 0 or line_total != grand_total or payment_total != grand_total:
        raise HTTPException(status_code=422, detail="Sale, line, and confirmed payment totals must match")

    sale_id = uuid.UUID(str(sale["sale_id"]))
    source_terminal_id = uuid.UUID(str(sale["terminal_id"]))
    source_cashier_id = uuid.UUID(str(sale["cashier_id"]))
    cursor = connection.execute(
        """
        INSERT INTO replica.sales(
            source_store_id,source_node_id,source_sale_id,source_terminal_id,source_cashier_id,
            receipt_number,business_date,currency_code,subtotal,discount_total,tax_total,
            rounding_amount,grand_total,paid_at
        ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        RETURNING id
        """,
        (
            node["store_id"], node["node_id"], sale_id, source_terminal_id, source_cashier_id,
            sale["receipt_number"], sale["business_date"], sale["currency_code"],
            _decimal(sale["subtotal"], "subtotal"), _decimal(sale.get("discount_total", "0"), "discount_total"),
            _decimal(sale.get("tax_total", "0"), "tax_total"),
            _decimal(sale.get("rounding_amount", "0"), "rounding_amount"),
            grand_total, sale["paid_at"],
        ),
    ).fetchone()
    cloud_sale_id = cursor["id"]

    for line in lines:
        connection.execute(
            """
            INSERT INTO replica.sale_lines(
                sale_id,source_store_id,source_line_id,source_product_id,sku_snapshot,name_snapshot,
                barcode_snapshot,quantity,unit_price,gross_amount,discount_amount,tax_code_snapshot,
                tax_rate_snapshot,tax_amount,line_total
            ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            """,
            (
                cloud_sale_id, node["store_id"], uuid.UUID(str(line["line_id"])),
                uuid.UUID(str(line["product_id"])) if line.get("product_id") else None,
                line["sku"], line["name"], line.get("barcode"), int(line["quantity"]),
                _decimal(line["unit_price"], "unit_price"), _decimal(line["gross_amount"], "gross_amount"),
                _decimal(line.get("discount_amount", "0"), "discount_amount"),
                line.get("tax_code"), _decimal(line.get("tax_rate", "0"), "tax_rate"),
                _decimal(line.get("tax_amount", "0"), "tax_amount"),
                _decimal(line["line_total"], "line_total"),
            ),
        )

    for payment in payments:
        connection.execute(
            """
            INSERT INTO replica.payments(
                sale_id,source_store_id,source_payment_id,payment_method_code,
                payment_method_name,amount,reference_number,confirmed_at
            ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
            """,
            (
                cloud_sale_id, node["store_id"], uuid.UUID(str(payment["payment_id"])),
                payment["method_code"], payment["method_name"],
                _decimal(payment["amount"], "payment.amount"), payment.get("reference_number"),
                payment["confirmed_at"],
            ),
        )
    connection.execute("SELECT replica.assert_sale_complete(%s)", (cloud_sale_id,))


@router.post("/api/v1/sync/events:batch")
def receive_event_batch(
    body: EventBatchInput,
    node: dict = Depends(require_scope("sync:events:write")),
    connection: Connection = Depends(get_connection),
):
    if str(body.source_node_id) != node["node_id"] or str(body.source_store_id) != node["store_id"]:
        raise HTTPException(status_code=403, detail="Source node/store does not match authenticated node")

    # current_node performs a SELECT on this pooled connection; close that read transaction
    # so each per-event transaction below commits before its final ACK is returned.
    connection.commit()
    results = []
    for event in body.events:
        payload_hash = _canonical_hash(event.payload)
        if payload_hash.hex() != event.payload_sha256.lower():
            raise HTTPException(status_code=422, detail=f"Payload hash mismatch for event {event.event_id}")

        with connection.transaction():
            existing = connection.execute(
                """
                SELECT event_id,idempotency_key,payload_sha256,status,processed_at
                FROM ingest.event_registry
                WHERE source_node_id=%s AND (event_id=%s OR idempotency_key=%s)
                """,
                (node["node_id"], event.event_id, event.idempotency_key),
            ).fetchone()
            if existing:
                # An idempotency key and event ID identify the same immutable event.
                # Reusing either identifier with a different counterpart must never
                # receive an ACK for an event that was not actually registered.
                if (str(existing["event_id"]) != str(event.event_id)
                        or existing["idempotency_key"] != event.idempotency_key):
                    raise HTTPException(status_code=409, detail="Event identity conflict")
                if bytes(existing["payload_sha256"]) != payload_hash:
                    raise HTTPException(status_code=409, detail="Event idempotency conflict: payload hash differs")
                if existing["status"] != "processed":
                    raise HTTPException(status_code=409, detail="Existing event is not in a final processed state")
                results.append({
                    "event_id": str(event.event_id),
                    "status": "already_processed",
                    "processed_at": existing["processed_at"].isoformat(),
                    "duplicate": True,
                })
                continue

            connection.execute(
                """
                INSERT INTO ingest.event_registry(
                    source_node_id,source_store_id,event_id,idempotency_key,aggregate_type,
                    aggregate_id,aggregate_version,event_type,schema_version,payload,
                    payload_sha256,occurred_at,status
                ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'received')
                """,
                (
                    node["node_id"], node["store_id"], event.event_id, event.idempotency_key,
                    event.aggregate_type, event.aggregate_id, event.aggregate_version,
                    event.event_type, event.schema_version, Jsonb(event.payload),
                    payload_hash, event.occurred_at,
                ),
            )
            _process_sale(connection, node, event)
            processed = connection.execute(
                """
                UPDATE ingest.event_registry
                SET status='processed',processed_at=now()
                WHERE source_node_id=%s AND event_id=%s
                RETURNING processed_at
                """,
                (node["node_id"], event.event_id),
            ).fetchone()
            results.append({
                "event_id": str(event.event_id),
                "status": "processed",
                "processed_at": processed["processed_at"].isoformat(),
                "duplicate": False,
            })

    return {"request_id": None, "results": results}
