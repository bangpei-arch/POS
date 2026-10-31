import uuid
from datetime import datetime, timezone
from typing import Any

from psycopg import Connection
from psycopg.types.json import Jsonb

from app.config import get_settings


def record_audit(
    connection: Connection,
    *,
    action: str,
    entity_type: str,
    entity_id: uuid.UUID | None,
    actor_id: uuid.UUID | None,
    reason: str | None = None,
    correlation_id: uuid.UUID | None = None,
) -> uuid.UUID:
    settings = get_settings()
    audit_id = uuid.uuid4()
    event_id = uuid.uuid4()
    occurred_at = datetime.now(timezone.utc)

    connection.execute(
        """
        INSERT INTO audit_events(
            id, store_id, terminal_id, actor_id, action, entity_type,
            entity_id, reason, correlation_id, occurred_at
        ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        """,
        (
            audit_id, settings.store_id, settings.terminal_id, actor_id,
            action, entity_type, entity_id, reason, correlation_id, occurred_at,
        ),
    )

    payload: dict[str, Any] = {
        "audit_id": str(audit_id),
        "actor_id": str(actor_id) if actor_id else None,
        "terminal_id": str(settings.terminal_id),
        "action": action,
        "entity_type": entity_type,
        "entity_id": str(entity_id) if entity_id else None,
        "reason": reason,
        "correlation_id": str(correlation_id) if correlation_id else None,
        "occurred_at": occurred_at.isoformat(),
    }
    connection.execute(
        """
        INSERT INTO sync_outbox(
            node_id, event_id, aggregate_type, aggregate_id,
            event_type, payload, schema_version, occurred_at
        ) VALUES (%s,%s,'audit',%s,'audit.recorded',%s,1,%s)
        """,
        (settings.store_node_id, event_id, audit_id, Jsonb(payload), occurred_at),
    )
    return audit_id
