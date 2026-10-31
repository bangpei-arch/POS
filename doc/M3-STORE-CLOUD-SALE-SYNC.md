# M3: Store-to-Cloud Sale Synchronization

**Status:** MVP implementation draft, stacked on PR #4 (M2).
**Scope:** One store server, one cloud node, `sale.paid` only.

## Flow

1. Store API writes a paid sale and its `sale.paid` outbox event in one local transaction.
2. Store Sender Worker claims the earliest event for an aggregate using `claim_sync_outbox`; the database lease and claim token fence stale workers.
3. Sender obtains a short-lived OAuth2 Client Credentials token and sends the event to `POST /api/v1/sync/events:batch`.
4. Cloud Receiver verifies that the authenticated node/store match the request, verifies the canonical SHA-256 payload hash, and accepts only `sale.paid`.
5. In one cloud DB transaction, receiver inserts the ingest registry row, replica sale header, all lines, all confirmed payments, checks totals, and marks the event processed.
6. Cloud returns `processed`; a retry of the same event/hash returns `already_processed`. Sender marks the local outbox sent only for those final statuses.

## Reliability and safety

- At-least-once network delivery; idempotent cloud processing by source node + event ID/idempotency key.
- Unique cloud constraints prevent duplicate source sale, line, payment, and event records.
- A different payload hash for an existing event is a conflict (HTTP 409), not an overwrite.
- Store outbox lease claim is committed before network I/O; ACK/failure functions require the current claim token and unexpired lease.
- Network and server failures are retried with jitter. Permanent 4xx responses become failed outbox rows for operator review.
- No cloud credential is placed on a POS terminal.

## MVP limitations

- Only `sale.paid` is replicated. Refunds, cash sessions, customers, promotions, stock deduction, incremental master sync, and UI are out of scope.
- Sender runs as a command/worker process; process supervision and production deployment are separate operational tasks.
- Store migration 006 adds a filtered outbox claim. The M3 sender claims only `sale.paid`; unsupported event types remain pending and do not consume retry attempts.
- Batch endpoint accepts up to 25 events, while the first sender implementation sends one event per request.
- This does not provide end-to-end exactly-once delivery; it provides at-least-once delivery with idempotent effects.

## Validation

Cloud API tests cover authenticated event ingestion, final ACK, retry duplicate behavior, and source-node mismatch. Full Debian integration is documented in `doc/DEBIAN13-M3-END-TO-END.md` and must use separate store and cloud PostgreSQL databases with a provisioned matching test node; never point cloud and store DSNs at the same database.
