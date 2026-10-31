from datetime import datetime, timedelta, timezone

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from psycopg import Connection

from app.audit import record_audit
from app.config import get_settings
from app.database import get_connection
from app.security import current_cashier, issue_store_token

router = APIRouter()
_hasher = PasswordHasher()


class LoginInput(BaseModel):
    employee_code: str = Field(min_length=1, max_length=40)
    pin: str = Field(min_length=4, max_length=12)


def _pin_matches(pin: str, encoded: str) -> bool:
    try:
        return _hasher.verify(encoded, pin)
    except (VerifyMismatchError, InvalidHashError, ValueError):
        return False


@router.post("/api/v1/auth/login")
def login(body: LoginInput, connection: Connection = Depends(get_connection)):
    settings = get_settings()
    user = connection.execute(
        """
        SELECT id, employee_code, full_name, pin_hash, status,
               failed_pin_attempts, locked_until
        FROM iam_users WHERE employee_code = %s
        """,
        (body.employee_code.strip(),),
    ).fetchone()

    if not user:
        with connection.transaction():
            record_audit(
                connection, action="auth.login_failed", entity_type="user",
                entity_id=None, actor_id=None, reason="unknown_employee_code",
            )
        connection.commit()
        raise HTTPException(status_code=401, detail="Employee code or PIN is incorrect")

    now = datetime.now(timezone.utc)
    if user["status"] == "locked" and user["locked_until"] and user["locked_until"] > now:
        raise HTTPException(status_code=423, detail="Cashier login is temporarily locked")

    if user["status"] == "locked":
        connection.execute(
            """
            UPDATE iam_users SET status='active', failed_pin_attempts=0,
                locked_until=NULL, updated_at=now()
            WHERE id=%s
            """,
            (user["id"],),
        )
        user["status"] = "active"
        user["failed_pin_attempts"] = 0

    if user["status"] != "active" or not _pin_matches(body.pin, user["pin_hash"]):
        attempts = min(int(user["failed_pin_attempts"]) + 1, 5)
        locked = attempts >= 5
        connection.execute(
            """
            UPDATE iam_users
            SET failed_pin_attempts=%s,
                status=CASE WHEN %s THEN 'locked' ELSE status END,
                locked_until=CASE WHEN %s THEN now() + interval '15 minutes' ELSE locked_until END,
                updated_at=now()
            WHERE id=%s
            """,
            (attempts, locked, locked, user["id"]),
        )
        record_audit(
            connection, action="auth.login_failed", entity_type="user",
            entity_id=user["id"], actor_id=user["id"], reason="invalid_pin_or_inactive",
        )
        connection.commit()
        raise HTTPException(status_code=401, detail="Employee code or PIN is incorrect")

    assignment = connection.execute(
        """
        SELECT r.code
        FROM iam_user_store_assignments usa
        JOIN iam_user_role_assignments ura
          ON ura.user_id = usa.user_id AND ura.store_id = usa.store_id
        JOIN iam_roles r ON r.id = ura.role_id
        WHERE usa.user_id = %s AND usa.store_id = %s
          AND usa.valid_from <= now() AND (usa.valid_until IS NULL OR usa.valid_until > now())
          AND ura.valid_from <= now() AND (ura.valid_until IS NULL OR ura.valid_until > now())
        """,
        (user["id"], settings.store_id),
    ).fetchall()
    roles = [row["code"] for row in assignment]
    if "CASHIER" not in roles:
        raise HTTPException(status_code=403, detail="Cashier is not assigned to this store")

    terminal = connection.execute(
        """
        SELECT is_active, primary_cashier_id
        FROM org_terminals WHERE id=%s AND store_id=%s
        """,
        (settings.terminal_id, settings.store_id),
    ).fetchone()
    if not terminal or not terminal["is_active"]:
        raise HTTPException(status_code=403, detail="Terminal is inactive or not registered")
    if terminal["primary_cashier_id"] and terminal["primary_cashier_id"] != user["id"]:
        raise HTTPException(status_code=403, detail="Cashier is not authorized for this terminal")

    connection.execute(
        """
        UPDATE iam_users SET failed_pin_attempts=0, locked_until=NULL, updated_at=now()
        WHERE id=%s
        """,
        (user["id"],),
    )
    token = issue_store_token(str(user["id"]), roles)
    return {
        "access_token": token,
        "token_type": "Bearer",
        "expires_in": settings.store_jwt_ttl_seconds,
        "cashier": {
            "id": str(user["id"]),
            "employee_code": user["employee_code"],
            "full_name": user["full_name"],
            "roles": roles,
        },
        "terminal_id": str(settings.terminal_id),
    }


@router.get("/api/v1/auth/me")
def me(cashier: dict = Depends(current_cashier)):
    return cashier
