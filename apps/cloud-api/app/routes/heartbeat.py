from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from psycopg import Connection

from app.database import get_connection
from app.security import require_scope

router = APIRouter()


class HeartbeatInput(BaseModel):
    app_version: str | None = Field(default=None, max_length=40)


@router.post("/api/v1/sync/heartbeat")
def heartbeat(
    body: HeartbeatInput,
    node: dict = Depends(require_scope("sync:heartbeat:write")),
    connection: Connection = Depends(get_connection),
):
    now = datetime.now(timezone.utc)
    connection.execute(
        """
        UPDATE cloud.sync_nodes
        SET last_seen_at = %s,
            app_version = COALESCE(%s, app_version)
        WHERE id = %s AND store_id = %s AND status = 'active'
        """,
        (now, body.app_version, node["node_id"], node["store_id"]),
    )
    return {"status": "ok", "server_time": now.isoformat()}
