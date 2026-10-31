from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from psycopg import Connection

from app.database import get_connection
from app.security import (
    issue_access_token,
    parse_basic_credentials,
    verify_client_secret,
)

router = APIRouter()


@router.post("/api/v1/oauth/token")
async def create_token(
    request: Request,
    connection: Connection = Depends(get_connection),
):
    content_type = request.headers.get("content-type", "")
    if "application/x-www-form-urlencoded" not in content_type:
        raise HTTPException(status_code=415, detail="Expected form-urlencoded body")

    try:
        form_body = (await request.body()).decode("utf-8")
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="invalid_request_body") from None
    form = parse_qs(form_body, keep_blank_values=True)
    if form.get("grant_type", [""])[0] != "client_credentials":
        raise HTTPException(status_code=400, detail="unsupported_grant_type")

    client_id, client_secret = parse_basic_credentials(request.headers.get("authorization"))
    row = connection.execute(
        """
        SELECT c.node_id, c.client_secret_hash, c.scopes, c.credential_version,
               n.store_id
        FROM cloud.node_credentials c
        JOIN cloud.sync_nodes n ON n.id = c.node_id
        WHERE c.client_id = %s
          AND n.status = 'active'
          AND c.revoked_at IS NULL
          AND c.valid_from <= now()
          AND (c.valid_until IS NULL OR c.valid_until > now())
        ORDER BY c.valid_from DESC
        LIMIT 1
        """,
        (client_id,),
    ).fetchone()

    if not row or not verify_client_secret(client_secret, row["client_secret_hash"]):
        raise HTTPException(
            status_code=401,
            detail="invalid_client",
            headers={"WWW-Authenticate": 'Basic realm="pos-cloud-token"'},
        )

    allowed_scopes = list(row["scopes"])
    requested_scope = form.get("scope", [""])[0].split()
    granted_scopes = requested_scope or allowed_scopes
    if any(scope not in allowed_scopes for scope in granted_scopes):
        raise HTTPException(status_code=400, detail="invalid_scope")

    token, expires_in = issue_access_token(
        node_id=str(row["node_id"]),
        store_id=str(row["store_id"]),
        credential_version=row["credential_version"],
        scopes=granted_scopes,
    )
    return JSONResponse(
        content={
            "access_token": token,
            "token_type": "Bearer",
            "expires_in": expires_in,
            "scope": " ".join(granted_scopes),
        },
        headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
    )
