import argparse
import hashlib
import json
import secrets
import sys
import time
import uuid
from pathlib import Path
from datetime import datetime, timedelta, timezone

import httpx
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings


def canonical_payload_hash(payload: dict) -> str:
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def get_token(client: httpx.Client, settings) -> str:
    response = client.post(
        f"{settings.cloud_api_base_url.rstrip('/')}/api/v1/oauth/token",
        data={"grant_type": "client_credentials", "scope": "sync:events:write"},
        auth=(settings.cloud_client_id, settings.cloud_client_secret),
    )
    response.raise_for_status()
    return response.json()["access_token"]


def run_once(settings, worker_id: str, limit: int = 10) -> int:
    if not settings.cloud_api_base_url or not settings.cloud_client_id or not settings.cloud_client_secret:
        raise RuntimeError("CLOUD_API_BASE_URL, CLOUD_CLIENT_ID, and CLOUD_CLIENT_SECRET are required")

    sent = 0
    with psycopg.connect(settings.store_database_url, row_factory=dict_row,
                         options="-c search_path=pos,public") as connection:
        rows = connection.execute(
            "SELECT * FROM claim_sync_outbox_for_types(%s,%s,%s,120)",
            (worker_id, ["sale.paid"], limit),
        ).fetchall()
        connection.commit()  # Release claim locks before making network requests.

        with httpx.Client(timeout=httpx.Timeout(15.0, connect=5.0)) as client:
            token = None
            for row in rows:
                payload = row["payload"]
                envelope = {
                    "event_id": str(row["event_id"]),
                    "idempotency_key": f'{row["node_id"]}:{row["event_id"]}',
                    "aggregate_type": row["aggregate_type"],
                    "aggregate_id": str(row["aggregate_id"]),
                    "aggregate_version": row["aggregate_version"],
                    "event_type": row["event_type"],
                    "schema_version": row["schema_version"],
                    "occurred_at": row["occurred_at"].astimezone(timezone.utc).isoformat(),
                    "payload_sha256": canonical_payload_hash(payload),
                    "payload": payload,
                }
                try:
                    if token is None:
                        token = get_token(client, settings)
                    response = client.post(
                        f"{settings.cloud_api_base_url.rstrip('/')}/api/v1/sync/events:batch",
                        json={
                            "protocol_version": 1,
                            "source_node_id": str(row["node_id"]),
                            "source_store_id": str(settings.store_id),
                            "worker_id": worker_id,
                            "events": [envelope],
                        },
                        headers={"Authorization": f"Bearer {token}", "X-Request-ID": str(uuid.uuid4())},
                    )
                    if response.status_code == 401:
                        token = get_token(client, settings)
                        response = client.post(
                            f"{settings.cloud_api_base_url.rstrip('/')}/api/v1/sync/events:batch",
                            json={
                                "protocol_version": 1,
                                "source_node_id": str(row["node_id"]),
                                "source_store_id": str(settings.store_id),
                                "worker_id": worker_id,
                                "events": [envelope],
                            },
                            headers={"Authorization": f"Bearer {token}", "X-Request-ID": str(uuid.uuid4())},
                        )
                    response.raise_for_status()
                    result = response.json()["results"][0]
                    if result["status"] not in ("processed", "already_processed"):
                        raise RuntimeError(f'Cloud did not final-ACK event: {result["status"]}')
                    acked = connection.execute(
                        "SELECT ack_sync_outbox(%s,%s,%s,%s) AS acked",
                        (row["id"], row["claim_token"], response.status_code,
                         Jsonb({"event_id": result["event_id"], "status": result["status"],
                                "processed_at": result["processed_at"]})),
                    ).fetchone()["acked"]
                    if acked:
                        sent += 1
                except Exception as exc:
                    status_code = getattr(getattr(exc, "response", None), "status_code", None)
                    permanent = status_code is not None and 400 <= status_code < 500 and status_code not in (408, 429)
                    attempts = int(row["attempts"])
                    delay_cap = min(900, 2 ** min(attempts, 10))
                    retry_at = datetime.now(timezone.utc) + timedelta(
                        seconds=secrets.randbelow(max(1, delay_cap)) + 1
                    )
                    connection.execute(
                        """
                        SELECT fail_sync_outbox(%s,%s,%s,%s,%s,%s,%s)
                        """,
                        (row["id"], row["claim_token"], str(exc)[:2000],
                         "http_permanent" if permanent else "transport_or_server",
                         None if permanent else retry_at, permanent, status_code),
                    )
        connection.commit()
    return sent


def main():
    parser = argparse.ArgumentParser(description="Deliver store outbox events to POS Cloud")
    parser.add_argument("--once", action="store_true", help="Claim and deliver one batch, then exit")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--worker-id", default=f"store-sender-{uuid.uuid4().hex[:8]}")
    parser.add_argument("--poll-seconds", type=int, default=5)
    args = parser.parse_args()
    settings = get_settings()
    while True:
        count = run_once(settings, args.worker_id, args.limit)
        print(f"ACKed {count} event(s)")
        if args.once:
            break
        time.sleep(max(1, args.poll_seconds))


if __name__ == "__main__":
    main()
