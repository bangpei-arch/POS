import base64
import binascii
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from fastapi import Depends, HTTPException, Request, status
from psycopg import Connection

from app.config import get_settings
from app.database import get_connection

_password_hasher = PasswordHasher()


def parse_basic_credentials(authorization: str | None) -> tuple[str, str]:
    if not authorization or not authorization.startswith("Basic "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Client authentication required",
            headers={"WWW-Authenticate": 'Basic realm="pos-cloud-token"'},
        )
    try:
        decoded = base64.b64decode(authorization[6:], validate=True).decode("utf-8")
        client_id, client_secret = decoded.split(":", 1)
        if not client_id or not client_secret:
            raise ValueError("empty credential")
        return client_id, client_secret
    except (ValueError, UnicodeDecodeError, binascii.Error):
        raise HTTPException(status_code=401, detail="Invalid client authentication") from None


def verify_client_secret(secret: str, encoded_hash: str) -> bool:
    try:
        return _password_hasher.verify(encoded_hash, secret)
    except (VerifyMismatchError, InvalidHashError, ValueError):
        return False


def issue_access_token(
    *,
    node_id: str,
    store_id: str,
    credential_version: int,
    scopes: list[str],
) -> tuple[str, int]:
    settings = get_settings()
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(seconds=settings.token_ttl_seconds)
    private_key = settings.jwt_private_key_path.read_text(encoding="utf-8")
    claims: dict[str, Any] = {
        "iss": settings.jwt_issuer,
        "sub": node_id,
        "aud": settings.jwt_audience,
        "iat": now,
        "nbf": now,
        "exp": expires_at,
        "jti": __import__("uuid").uuid4().hex,
        "scope": " ".join(scopes),
        "store_id": store_id,
        "cred_ver": credential_version,
    }
    token = jwt.encode(
        claims,
        private_key,
        algorithm="RS256",
        headers={"kid": settings.jwt_kid, "typ": "JWT"},
    )
    return token, settings.token_ttl_seconds


def current_node(
    request: Request,
    connection: Connection = Depends(get_connection),
) -> dict[str, Any]:
    settings = get_settings()
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Bearer token required")
    token = header[7:].strip()
    try:
        public_key = settings.jwt_public_key_path.read_text(encoding="utf-8")
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "nbf", "sub", "store_id", "cred_ver"]},
        )
    except (jwt.PyJWTError, OSError):
        raise HTTPException(status_code=401, detail="Invalid or expired access token") from None

    row = connection.execute(
        """
        SELECT n.id AS node_id, n.store_id, n.status AS node_status,
               c.credential_version, c.scopes
        FROM cloud.sync_nodes n
        JOIN cloud.node_credentials c ON c.node_id = n.id
        WHERE n.id = %s
          AND n.store_id = %s
          AND n.status = 'active'
          AND c.credential_version = %s
          AND c.revoked_at IS NULL
          AND (c.valid_until IS NULL OR c.valid_until > now())
        ORDER BY c.valid_from DESC
        LIMIT 1
        """,
        (claims["sub"], claims["store_id"], claims["cred_ver"]),
    ).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Node credential revoked or inactive")

    return {
        "node_id": str(row["node_id"]),
        "store_id": str(row["store_id"]),
        "scopes": list(row["scopes"]),
    }


def require_scope(scope: str):
    def dependency(node: dict[str, Any] = Depends(current_node)) -> dict[str, Any]:
        if scope not in node["scopes"]:
            raise HTTPException(status_code=403, detail="Insufficient scope")
        return node
    return dependency
