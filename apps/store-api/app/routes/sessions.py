import uuid
from datetime import datetime, timezone
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from psycopg import Connection
from psycopg.types.json import Jsonb

from app.audit import record_audit
from app.config import get_settings
from app.database import get_connection
from app.security import current_cashier

router = APIRouter()


class OpenSessionInput(BaseModel):
    opening_counted: Decimal = Field(ge=0)


class CloseSessionInput(BaseModel):
    closing_counted: Decimal = Field(ge=0)


@router.get("/api/v1/sessions/current")
def current_session(
    cashier: dict = Depends(current_cashier),
    connection: Connection = Depends(get_connection),
):
    row = connection.execute(
        """
        SELECT id, opening_counted, opened_at, status
        FROM cash_sessions
        WHERE store_id=%s AND terminal_id=%s AND cashier_id=%s AND status='open'
        ORDER BY opened_at DESC LIMIT 1
        """,
        (cashier["store_id"], cashier["terminal_id"], cashier["user_id"]),
    ).fetchone()
    if not row:
        return {"session": None}
    return {
        "session": {
            "id": str(row["id"]),
            "opening_counted": format(row["opening_counted"], ".2f"),
            "opened_at": row["opened_at"].isoformat(),
            "status": row["status"],
        }
    }


@router.post("/api/v1/sessions/open")
def open_session(
    body: OpenSessionInput,
    cashier: dict = Depends(current_cashier),
    connection: Connection = Depends(get_connection),
):
    settings = get_settings()
    with connection.transaction():
        existing = connection.execute(
            """
            SELECT id, opening_counted, opened_at
            FROM cash_sessions
            WHERE drawer_id = (
                SELECT id FROM cash_drawers
                WHERE terminal_id=%s AND store_id=%s AND is_active
            ) AND status='open'
            """,
            (settings.terminal_id, settings.store_id),
        ).fetchone()
        if existing:
            if connection.execute(
                "SELECT cashier_id FROM cash_sessions WHERE id=%s", (existing["id"],)
            ).fetchone()["cashier_id"] != uuid.UUID(cashier["user_id"]):
                raise HTTPException(status_code=409, detail="Cash drawer already has an open session")
            return {
                "session_id": str(existing["id"]),
                "opening_counted": format(existing["opening_counted"], ".2f"),
                "opened_at": existing["opened_at"].isoformat(),
                "already_open": True,
            }

        drawer = connection.execute(
            """
            SELECT id FROM cash_drawers
            WHERE terminal_id=%s AND store_id=%s AND is_active
            """,
            (settings.terminal_id, settings.store_id),
        ).fetchone()
        if not drawer:
            raise HTTPException(status_code=409, detail="Active cash drawer is not configured")

        session_id = uuid.uuid4()
        opened_at = datetime.now(timezone.utc)
        connection.execute(
            """
            INSERT INTO cash_sessions(
                id, drawer_id, store_id, terminal_id, cashier_id,
                status, opening_counted, opened_at
            ) VALUES (%s,%s,%s,%s,%s,'open',%s,%s)
            """,
            (
                session_id, drawer["id"], settings.store_id, settings.terminal_id,
                cashier["user_id"], body.opening_counted, opened_at,
            ),
        )
        connection.execute(
            """
            INSERT INTO cash_session_events(session_id,event_type,actor_id,event_data)
            VALUES (%s,'opened',%s,%s)
            """,
            (session_id, cashier["user_id"], Jsonb({"opening_counted": format(body.opening_counted, ".2f")})),
        )
        record_audit(
            connection, action="cash_session.opened", entity_type="cash_session",
            entity_id=session_id, actor_id=uuid.UUID(cashier["user_id"]),
        )
    return {
        "session_id": str(session_id),
        "opening_counted": format(body.opening_counted, ".2f"),
        "opened_at": opened_at.isoformat(),
        "already_open": False,
    }


@router.post("/api/v1/sessions/{session_id}/close")
def close_session(
    session_id: uuid.UUID,
    body: CloseSessionInput,
    cashier: dict = Depends(current_cashier),
    connection: Connection = Depends(get_connection),
):
    with connection.transaction():
        session = connection.execute(
            """
            SELECT id, opening_counted, status
            FROM cash_sessions
            WHERE id=%s AND store_id=%s AND terminal_id=%s AND cashier_id=%s
            FOR UPDATE
            """,
            (session_id, cashier["store_id"], cashier["terminal_id"], cashier["user_id"]),
        ).fetchone()
        if not session:
            raise HTTPException(status_code=404, detail="Cash session not found")
        if session["status"] != "open":
            raise HTTPException(status_code=409, detail="Cash session is already closed")

        cash_sales = connection.execute(
            """
            SELECT COALESCE(sum(p.amount),0) AS cash_total
            FROM pos_sales s
            JOIN pos_payments p ON p.sale_id=s.id
            JOIN md_payment_methods pm ON pm.id=p.payment_method_id
            WHERE s.cash_session_id=%s AND s.status='paid'
              AND p.status='confirmed' AND pm.is_cash
            """,
            (session_id,),
        ).fetchone()["cash_total"]
        expected = session["opening_counted"] + cash_sales
        variance = body.closing_counted - expected
        closed_at = datetime.now(timezone.utc)
        connection.execute(
            """
            UPDATE cash_sessions
            SET status='closed', closing_counted=%s, expected_cash=%s,
                variance_amount=%s, closed_at=%s
            WHERE id=%s
            """,
            (body.closing_counted, expected, variance, closed_at, session_id),
        )
        connection.execute(
            """
            INSERT INTO cash_session_events(session_id,event_type,actor_id,event_data)
            VALUES (%s,'closed',%s,%s)
            """,
            (
                session_id, cashier["user_id"],
                Jsonb({
                    "closing_counted": format(body.closing_counted, ".2f"),
                    "expected_cash": format(expected, ".2f"),
                    "variance_amount": format(variance, ".2f"),
                }),
            ),
        )
        record_audit(
            connection, action="cash_session.closed", entity_type="cash_session",
            entity_id=session_id, actor_id=uuid.UUID(cashier["user_id"]),
        )
    return {
        "session_id": str(session_id),
        "status": "closed",
        "closing_counted": format(body.closing_counted, ".2f"),
        "expected_cash": format(expected, ".2f"),
        "variance_amount": format(variance, ".2f"),
        "closed_at": closed_at.isoformat(),
    }
