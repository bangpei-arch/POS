import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
from fastapi import Depends, HTTPException, Request
from psycopg import Connection

from app.config import get_settings
from app.database import get_connection


def issue_store_token(user_id: str, role_codes: list[str]) -> str:
    settings = get_settings()
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "iss": "pos-store",
            "aud": "pos-store-api",
            "sub": user_id,
            "store_id": str(settings.store_id),
            "terminal_id": str(settings.terminal_id),
            "roles": role_codes,
            "iat": now,
            "nbf": now,
            "exp": now + timedelta(seconds=settings.store_jwt_ttl_seconds),
            "jti": uuid.uuid4().hex,
        },
        settings.store_jwt_secret,
        algorithm="HS256",
    )


def current_cashier(
    request: Request,
    connection: Connection = Depends(get_connection),
) -> dict[str, Any]:
    settings = get_settings()
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Login required")
    try:
        claims = jwt.decode(
            header[7:].strip(),
            settings.store_jwt_secret,
            algorithms=["HS256"],
            audience="pos-store-api",
            issuer="pos-store",
            options={"require": ["exp", "iat", "nbf", "sub", "store_id", "terminal_id"]},
        )
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="Invalid or expired local session") from None

    if claims["store_id"] != str(settings.store_id) or claims["terminal_id"] != str(settings.terminal_id):
        raise HTTPException(status_code=403, detail="Token is not valid for this store terminal")

    row = connection.execute(
        """
        SELECT u.id, u.employee_code, u.full_name, u.status
        FROM iam_users u
        JOIN iam_user_store_assignments usa
          ON usa.user_id = u.id AND usa.store_id = %s
         AND usa.valid_from <= now()
         AND (usa.valid_until IS NULL OR usa.valid_until > now())
        JOIN iam_user_role_assignments ura
          ON ura.user_id = u.id AND ura.store_id = %s
         AND ura.valid_from <= now()
         AND (ura.valid_until IS NULL OR ura.valid_until > now())
        JOIN iam_roles r ON r.id = ura.role_id AND r.code = 'CASHIER'
        WHERE u.id = %s AND u.status = 'active'
        LIMIT 1
        """,
        (settings.store_id, settings.store_id, claims["sub"]),
    ).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Cashier is inactive or no longer assigned")

    return {
        "user_id": str(row["id"]),
        "employee_code": row["employee_code"],
        "full_name": row["full_name"],
        "store_id": str(settings.store_id),
        "terminal_id": str(settings.terminal_id),
    }
