-- Sync recovery, lease fencing, aggregate ordering, and inbox processing.
-- Apply after 001_initial_schema.sql, 002_integrity_guards.sql, and 003_transaction_finality.sql.
BEGIN;
SET search_path TO pos, public;

-- ---------------------------------------------------------------------------
-- Outbox: deterministic per-aggregate sequence and fenced worker leases.
-- ---------------------------------------------------------------------------
ALTER TABLE sync_outbox
  ADD COLUMN aggregate_version bigint,
  ADD COLUMN claimed_by varchar(120),
  ADD COLUMN claim_token uuid,
  ADD COLUMN claimed_at timestamptz,
  ADD COLUMN lease_until timestamptz,
  ADD COLUMN acked_at timestamptz,
  ADD COLUMN ack_payload jsonb,
  ADD COLUMN last_error_class varchar(40),
  ADD COLUMN max_attempts integer NOT NULL DEFAULT 12;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY node_id, aggregate_type, aggregate_id
           ORDER BY occurred_at, id
         ) AS version_no
  FROM sync_outbox
)
UPDATE sync_outbox o
SET aggregate_version = ranked.version_no
FROM ranked
WHERE ranked.id = o.id;

-- A pre-migration "sending" row has no trustworthy lease owner. Requeue it
-- before validating the new status/lease shape constraint.
UPDATE sync_outbox
SET status = 'pending',
    claimed_by = NULL,
    claim_token = NULL,
    claimed_at = NULL,
    lease_until = NULL
WHERE status = 'sending';

ALTER TABLE sync_outbox
  ALTER COLUMN aggregate_version SET NOT NULL,
  ALTER COLUMN max_attempts SET DEFAULT 12,
  ADD CONSTRAINT ck_sync_outbox_aggregate_version CHECK (aggregate_version > 0),
  ADD CONSTRAINT ck_sync_outbox_max_attempts CHECK (max_attempts BETWEEN 1 AND 100),
  ADD CONSTRAINT ck_sync_outbox_lease_shape CHECK (
    (status = 'sending' AND claimed_by IS NOT NULL AND claim_token IS NOT NULL
      AND claimed_at IS NOT NULL AND lease_until IS NOT NULL)
    OR
    (status <> 'sending' AND claimed_by IS NULL AND claim_token IS NULL
      AND claimed_at IS NULL AND lease_until IS NULL)
  );

CREATE UNIQUE INDEX uq_sync_outbox_aggregate_version
  ON sync_outbox(node_id, aggregate_type, aggregate_id, aggregate_version);
CREATE INDEX ix_sync_outbox_expired_lease
  ON sync_outbox(lease_until, occurred_at)
  WHERE status = 'sending';
CREATE INDEX ix_sync_outbox_aggregate_order
  ON sync_outbox(node_id, aggregate_type, aggregate_id, aggregate_version, status);

CREATE TABLE sync_aggregate_counters (
  node_id uuid NOT NULL REFERENCES sync_nodes(id),
  aggregate_type varchar(60) NOT NULL,
  aggregate_id uuid NOT NULL,
  last_version bigint NOT NULL CHECK (last_version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (node_id, aggregate_type, aggregate_id)
);

INSERT INTO sync_aggregate_counters(node_id, aggregate_type, aggregate_id, last_version)
SELECT node_id, aggregate_type, aggregate_id, max(aggregate_version)
FROM sync_outbox
GROUP BY node_id, aggregate_type, aggregate_id
ON CONFLICT (node_id, aggregate_type, aggregate_id)
DO UPDATE SET last_version = GREATEST(
  sync_aggregate_counters.last_version, EXCLUDED.last_version
), updated_at = now();

CREATE OR REPLACE FUNCTION sync_assign_outbox_aggregate_version()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
BEGIN
  INSERT INTO sync_aggregate_counters(
    node_id, aggregate_type, aggregate_id, last_version
  ) VALUES (
    NEW.node_id, NEW.aggregate_type, NEW.aggregate_id, 1
  )
  ON CONFLICT (node_id, aggregate_type, aggregate_id)
  DO UPDATE SET
    last_version = sync_aggregate_counters.last_version + 1,
    updated_at = now()
  RETURNING last_version INTO NEW.aggregate_version;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_outbox_assign_aggregate_version
BEFORE INSERT ON sync_outbox
FOR EACH ROW EXECUTE FUNCTION sync_assign_outbox_aggregate_version();

CREATE OR REPLACE FUNCTION sync_guard_outbox_aggregate_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
BEGIN
  IF NEW.node_id IS DISTINCT FROM OLD.node_id
     OR NEW.aggregate_type IS DISTINCT FROM OLD.aggregate_type
     OR NEW.aggregate_id IS DISTINCT FROM OLD.aggregate_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version THEN
    RAISE EXCEPTION 'Outbox aggregate identity and version are immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_outbox_aggregate_identity_immutable
BEFORE UPDATE ON sync_outbox
FOR EACH ROW EXECUTE FUNCTION sync_guard_outbox_aggregate_identity();

ALTER TABLE sync_delivery_attempts
  ADD COLUMN claim_token uuid,
  ADD COLUMN worker_id varchar(120);

-- Claim only the earliest non-ACKed event for each aggregate. A failed event
-- intentionally blocks later versions until an operator resolves/replays it.
CREATE OR REPLACE FUNCTION claim_sync_outbox(
  p_worker_id varchar(120),
  p_limit integer DEFAULT 25,
  p_lease_seconds integer DEFAULT 120
)
RETURNS SETOF sync_outbox
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
BEGIN
  IF p_worker_id IS NULL OR length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker_id is required';
  END IF;
  IF p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'claim limit must be between 1 and 200';
  END IF;
  IF p_lease_seconds < 15 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease must be between 15 and 900 seconds';
  END IF;

  UPDATE sync_outbox
  SET status = 'failed',
      last_error = COALESCE(last_error, 'Lease expired after maximum attempts'),
      last_error_class = COALESCE(last_error_class, 'lease_exhausted'),
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE status = 'sending'
    AND lease_until <= now()
    AND attempts >= max_attempts;

  RETURN QUERY
  WITH candidates AS (
    SELECT o.id
    FROM sync_outbox o
    WHERE o.attempts < o.max_attempts
      AND (
        (o.status = 'pending' AND COALESCE(o.next_retry_at, '-infinity'::timestamptz) <= now())
        OR
        (o.status = 'sending' AND o.lease_until <= now())
      )
      AND NOT EXISTS (
        SELECT 1
        FROM sync_outbox prior
        WHERE prior.node_id = o.node_id
          AND prior.aggregate_type = o.aggregate_type
          AND prior.aggregate_id = o.aggregate_id
          AND prior.aggregate_version < o.aggregate_version
          AND prior.status <> 'sent'
      )
    ORDER BY o.occurred_at, o.id
    FOR UPDATE OF o SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE sync_outbox o
  SET status = 'sending',
      attempts = o.attempts + 1,
      claimed_by = p_worker_id,
      claim_token = gen_random_uuid(),
      claimed_at = now(),
      lease_until = now() + make_interval(secs => p_lease_seconds)
  FROM candidates c
  WHERE o.id = c.id
  RETURNING o.*;
END;
$$;

CREATE OR REPLACE FUNCTION ack_sync_outbox(
  p_outbox_id uuid,
  p_claim_token uuid,
  p_response_code integer DEFAULT 200,
  p_ack_payload jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_row sync_outbox%ROWTYPE;
  v_worker varchar(120);
BEGIN
  SELECT claimed_by INTO v_worker
  FROM sync_outbox
  WHERE id = p_outbox_id AND status = 'sending'
    AND claim_token = p_claim_token AND lease_until > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE sync_outbox
  SET status = 'sent',
      sent_at = now(),
      acked_at = now(),
      ack_payload = p_ack_payload,
      next_retry_at = NULL,
      last_error = NULL,
      last_error_class = NULL,
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE id = p_outbox_id
    AND status = 'sending'
    AND claim_token = p_claim_token
    AND lease_until > now()
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO sync_delivery_attempts(
    outbox_id, result, response_code, claim_token, worker_id
  ) VALUES (
    v_row.id, 'success', p_response_code, p_claim_token, v_worker
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION fail_sync_outbox(
  p_outbox_id uuid,
  p_claim_token uuid,
  p_error text,
  p_error_class varchar(40),
  p_retry_at timestamptz DEFAULT NULL,
  p_permanent boolean DEFAULT false,
  p_response_code integer DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_row sync_outbox%ROWTYPE;
  v_worker varchar(120);
  v_result varchar(20);
BEGIN
  SELECT * INTO v_row
  FROM sync_outbox
  WHERE id = p_outbox_id
    AND status = 'sending'
    AND claim_token = p_claim_token
    AND lease_until > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_worker := v_row.claimed_by;
  IF p_permanent OR v_row.attempts >= v_row.max_attempts THEN
    v_result := 'failed';
    UPDATE sync_outbox
    SET status = 'failed',
        last_error = p_error,
        last_error_class = p_error_class,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_outbox_id;
  ELSE
    IF p_retry_at IS NULL OR p_retry_at <= now() THEN
      RAISE EXCEPTION 'A future retry_at is required for transient errors';
    END IF;
    v_result := 'retry';
    UPDATE sync_outbox
    SET status = 'pending',
        next_retry_at = p_retry_at,
        last_error = p_error,
        last_error_class = p_error_class,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_outbox_id;
  END IF;

  INSERT INTO sync_delivery_attempts(
    outbox_id, result, response_code, error_message, claim_token, worker_id
  ) VALUES (
    p_outbox_id, v_result, p_response_code, p_error, p_claim_token, v_worker
  );
  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Inbox: source-scoped idempotency and ordered, leased processing.
-- ---------------------------------------------------------------------------
ALTER TABLE sync_inbox
  DROP CONSTRAINT sync_inbox_idempotency_key_key,
  ADD CONSTRAINT uq_sync_inbox_source_idempotency
    UNIQUE (source_node_id, idempotency_key);

ALTER TABLE sync_inbox
  ADD COLUMN aggregate_type varchar(60),
  ADD COLUMN aggregate_id uuid,
  ADD COLUMN aggregate_version bigint,
  ADD COLUMN claimed_by varchar(120),
  ADD COLUMN claim_token uuid,
  ADD COLUMN claimed_at timestamptz,
  ADD COLUMN lease_until timestamptz,
  ADD COLUMN processing_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN max_attempts integer NOT NULL DEFAULT 12,
  ADD COLUMN next_retry_at timestamptz,
  ADD COLUMN last_error text,
  ADD COLUMN processed_at timestamptz,
  ADD COLUMN ack_payload jsonb;

ALTER TABLE sync_inbox
  DROP CONSTRAINT sync_inbox_processing_status_check,
  ADD CONSTRAINT ck_sync_inbox_processing_status CHECK (
    processing_status IN ('received','processing','processed','rejected','deferred','failed')
  ),
  ADD CONSTRAINT ck_sync_inbox_aggregate_version CHECK (
    aggregate_version IS NULL OR aggregate_version > 0
  ),
  ADD CONSTRAINT ck_sync_inbox_max_attempts CHECK (max_attempts BETWEEN 1 AND 100),
  ADD CONSTRAINT ck_sync_inbox_attempts CHECK (processing_attempts >= 0),
  ADD CONSTRAINT ck_sync_inbox_lease_shape CHECK (
    (processing_status = 'processing' AND claimed_by IS NOT NULL
      AND claim_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_until IS NOT NULL)
    OR
    (processing_status <> 'processing' AND claimed_by IS NULL
      AND claim_token IS NULL AND claimed_at IS NULL AND lease_until IS NULL)
  );

CREATE UNIQUE INDEX uq_sync_inbox_aggregate_version
  ON sync_inbox(source_node_id, aggregate_type, aggregate_id, aggregate_version)
  WHERE aggregate_version IS NOT NULL;
CREATE INDEX ix_sync_inbox_expired_lease
  ON sync_inbox(lease_until, received_at)
  WHERE processing_status = 'processing';
CREATE INDEX ix_sync_inbox_aggregate_order
  ON sync_inbox(source_node_id, aggregate_type, aggregate_id, aggregate_version, processing_status)
  WHERE aggregate_version IS NOT NULL;

CREATE TABLE sync_inbox_aggregate_cursors (
  source_node_id uuid NOT NULL REFERENCES sync_nodes(id),
  aggregate_type varchar(60) NOT NULL,
  aggregate_id uuid NOT NULL,
  last_processed_version bigint NOT NULL DEFAULT 0 CHECK (last_processed_version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_node_id, aggregate_type, aggregate_id)
);

CREATE OR REPLACE FUNCTION claim_sync_inbox(
  p_worker_id varchar(120),
  p_limit integer DEFAULT 25,
  p_lease_seconds integer DEFAULT 120
)
RETURNS SETOF sync_inbox
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
BEGIN
  IF p_worker_id IS NULL OR length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker_id is required';
  END IF;
  IF p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'claim limit must be between 1 and 200';
  END IF;
  IF p_lease_seconds < 15 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease must be between 15 and 900 seconds';
  END IF;

  UPDATE sync_inbox
  SET processing_status = 'failed',
      last_error = COALESCE(last_error, 'Lease expired after maximum attempts'),
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE processing_status = 'processing'
    AND lease_until <= now()
    AND processing_attempts >= max_attempts;

  INSERT INTO sync_inbox_aggregate_cursors(source_node_id, aggregate_type, aggregate_id)
  SELECT DISTINCT source_node_id, aggregate_type, aggregate_id
  FROM sync_inbox
  WHERE aggregate_version IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN QUERY
  WITH candidates AS (
    SELECT i.id
    FROM sync_inbox i
    JOIN sync_inbox_aggregate_cursors c
      ON c.source_node_id = i.source_node_id
     AND c.aggregate_type = i.aggregate_type
     AND c.aggregate_id = i.aggregate_id
     AND i.aggregate_version = c.last_processed_version + 1
    WHERE i.aggregate_version IS NOT NULL
      AND i.processing_attempts < i.max_attempts
      AND COALESCE(i.next_retry_at, '-infinity'::timestamptz) <= now()
      AND (
        i.processing_status IN ('received','deferred')
        OR (i.processing_status = 'processing' AND i.lease_until <= now())
      )
    ORDER BY i.received_at, i.id
    FOR UPDATE OF i SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE sync_inbox i
  SET processing_status = 'processing',
      processing_attempts = i.processing_attempts + 1,
      claimed_by = p_worker_id,
      claim_token = gen_random_uuid(),
      claimed_at = now(),
      lease_until = now() + make_interval(secs => p_lease_seconds)
  FROM candidates c
  WHERE i.id = c.id
  RETURNING i.*;
END;
$$;

CREATE OR REPLACE FUNCTION complete_sync_inbox(
  p_inbox_id uuid,
  p_claim_token uuid,
  p_ack_payload jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_row sync_inbox%ROWTYPE;
  v_cursor bigint;
BEGIN
  SELECT * INTO v_row
  FROM sync_inbox
  WHERE id = p_inbox_id
    AND processing_status = 'processing'
    AND claim_token = p_claim_token
    AND lease_until > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT last_processed_version INTO v_cursor
  FROM sync_inbox_aggregate_cursors
  WHERE source_node_id = v_row.source_node_id
    AND aggregate_type = v_row.aggregate_type
    AND aggregate_id = v_row.aggregate_id
  FOR UPDATE;

  IF NOT FOUND OR v_row.aggregate_version <> v_cursor + 1 THEN
    RETURN false;
  END IF;

  UPDATE sync_inbox_aggregate_cursors
  SET last_processed_version = v_row.aggregate_version, updated_at = now()
  WHERE source_node_id = v_row.source_node_id
    AND aggregate_type = v_row.aggregate_type
    AND aggregate_id = v_row.aggregate_id;

  UPDATE sync_inbox
  SET processing_status = 'processed',
      processed_at = now(),
      response_payload = p_ack_payload,
      ack_payload = p_ack_payload,
      next_retry_at = NULL,
      last_error = NULL,
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE id = p_inbox_id;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION fail_sync_inbox(
  p_inbox_id uuid,
  p_claim_token uuid,
  p_error text,
  p_retry_at timestamptz DEFAULT NULL,
  p_permanent boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_row sync_inbox%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM sync_inbox
  WHERE id = p_inbox_id
    AND processing_status = 'processing'
    AND claim_token = p_claim_token
    AND lease_until > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF p_permanent OR v_row.processing_attempts >= v_row.max_attempts THEN
    UPDATE sync_inbox
    SET processing_status = 'rejected',
        last_error = p_error,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_inbox_id;
  ELSE
    IF p_retry_at IS NULL OR p_retry_at <= now() THEN
      RAISE EXCEPTION 'A future retry_at is required for transient errors';
    END IF;
    UPDATE sync_inbox
    SET processing_status = 'deferred',
        next_retry_at = p_retry_at,
        last_error = p_error,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_inbox_id;
  END IF;
  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Inventory API queue uses the same fenced-lease recovery model. It remains
-- a separate integration queue with its own idempotency key.
-- ---------------------------------------------------------------------------
ALTER TABLE sync_inventory_events
  ADD COLUMN claimed_by varchar(120),
  ADD COLUMN claim_token uuid,
  ADD COLUMN claimed_at timestamptz,
  ADD COLUMN lease_until timestamptz,
  ADD COLUMN max_attempts integer NOT NULL DEFAULT 12,
  ADD COLUMN acked_at timestamptz,
  ADD COLUMN ack_payload jsonb,
  ADD COLUMN last_error_class varchar(40);

UPDATE sync_inventory_events
SET status = 'pending',
    claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
WHERE status = 'sending';

ALTER TABLE sync_inventory_events
  ADD CONSTRAINT ck_sync_inventory_max_attempts CHECK (max_attempts BETWEEN 1 AND 100),
  ADD CONSTRAINT ck_sync_inventory_lease_shape CHECK (
    (status = 'sending' AND claimed_by IS NOT NULL AND claim_token IS NOT NULL
      AND claimed_at IS NOT NULL AND lease_until IS NOT NULL)
    OR
    (status <> 'sending' AND claimed_by IS NULL AND claim_token IS NULL
      AND claimed_at IS NULL AND lease_until IS NULL)
  );

CREATE TABLE sync_inventory_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inventory_event_id uuid NOT NULL REFERENCES sync_inventory_events(id),
  attempted_at timestamptz NOT NULL DEFAULT now(),
  result varchar(20) NOT NULL,
  worker_id varchar(120),
  claim_token uuid,
  error_class varchar(40),
  response_payload jsonb,
  error_message text
);
CREATE INDEX ix_sync_inventory_attempts_event_time
  ON sync_inventory_delivery_attempts(inventory_event_id, attempted_at DESC);

CREATE INDEX ix_sync_inventory_expired_lease
  ON sync_inventory_events(lease_until, created_at)
  WHERE status = 'sending';
CREATE INDEX ix_sync_inventory_due
  ON sync_inventory_events(status, next_retry_at, created_at);

CREATE OR REPLACE FUNCTION claim_sync_inventory_events(
  p_worker_id varchar(120),
  p_limit integer DEFAULT 25,
  p_lease_seconds integer DEFAULT 120
)
RETURNS SETOF sync_inventory_events
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
BEGIN
  IF p_worker_id IS NULL OR length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker_id is required';
  END IF;
  IF p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'claim limit must be between 1 and 200';
  END IF;
  IF p_lease_seconds < 15 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease must be between 15 and 900 seconds';
  END IF;

  UPDATE sync_inventory_events
  SET status = 'failed',
      last_error = COALESCE(last_error, 'Lease expired after maximum attempts'),
      last_error_class = COALESCE(last_error_class, 'lease_exhausted'),
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE status = 'sending' AND lease_until <= now() AND attempts >= max_attempts;

  RETURN QUERY
  WITH candidates AS (
    SELECT e.id
    FROM sync_inventory_events e
    WHERE e.attempts < e.max_attempts
      AND (
        (e.status = 'pending' AND COALESCE(e.next_retry_at, '-infinity'::timestamptz) <= now())
        OR (e.status = 'sending' AND e.lease_until <= now())
      )
    ORDER BY e.created_at, e.id
    FOR UPDATE OF e SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE sync_inventory_events e
  SET status = 'sending',
      attempts = e.attempts + 1,
      claimed_by = p_worker_id,
      claim_token = gen_random_uuid(),
      claimed_at = now(),
      lease_until = now() + make_interval(secs => p_lease_seconds)
  FROM candidates c
  WHERE e.id = c.id
  RETURNING e.*;
END;
$$;

CREATE OR REPLACE FUNCTION ack_sync_inventory_event(
  p_event_id uuid,
  p_claim_token uuid,
  p_response_payload jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_worker varchar(120);
BEGIN
  SELECT claimed_by INTO v_worker
  FROM sync_inventory_events
  WHERE id = p_event_id AND status = 'sending'
    AND claim_token = p_claim_token AND lease_until > now()
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  UPDATE sync_inventory_events
  SET status = 'sent', acked_at = now(), ack_payload = p_response_payload,
      next_retry_at = NULL, last_error = NULL, last_error_class = NULL,
      claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
  WHERE id = p_event_id AND status = 'sending'
    AND claim_token = p_claim_token AND lease_until > now();
  IF NOT FOUND THEN RETURN false; END IF;

  INSERT INTO sync_inventory_delivery_attempts(
    inventory_event_id, result, worker_id, claim_token, response_payload
  ) VALUES (p_event_id, 'success', v_worker, p_claim_token, p_response_payload);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION fail_sync_inventory_event(
  p_event_id uuid,
  p_claim_token uuid,
  p_error text,
  p_error_class varchar(40),
  p_retry_at timestamptz DEFAULT NULL,
  p_permanent boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_row sync_inventory_events%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM sync_inventory_events
  WHERE id = p_event_id AND status = 'sending'
    AND claim_token = p_claim_token AND lease_until > now()
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  IF p_permanent OR v_row.attempts >= v_row.max_attempts THEN
    UPDATE sync_inventory_events
    SET status = 'failed', last_error = p_error, last_error_class = p_error_class,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_event_id;
  ELSE
    IF p_retry_at IS NULL OR p_retry_at <= now() THEN
      RAISE EXCEPTION 'A future retry_at is required for transient errors';
    END IF;
    UPDATE sync_inventory_events
    SET status = 'pending', next_retry_at = p_retry_at,
        last_error = p_error, last_error_class = p_error_class,
        claimed_by = NULL, claim_token = NULL, claimed_at = NULL, lease_until = NULL
    WHERE id = p_event_id;
  END IF;

  INSERT INTO sync_inventory_delivery_attempts(
    inventory_event_id, result, worker_id, claim_token, error_class, error_message
  ) VALUES (
    p_event_id,
    CASE WHEN p_permanent OR v_row.attempts >= v_row.max_attempts THEN 'failed' ELSE 'retry' END,
    v_row.claimed_by, p_claim_token, p_error_class, p_error
  );
  RETURN true;
END;
$$;

COMMENT ON COLUMN sync_outbox.sent_at IS
  'Compatibility timestamp; set only after a valid receiver ACK. Not merely HTTP send time.';
COMMENT ON COLUMN sync_outbox.aggregate_version IS
  'Monotonic per node + aggregate type + aggregate id; allocated transactionally by trigger.';
COMMENT ON COLUMN sync_checkpoints.last_event_id IS
  'Observability watermark only until a globally ordered stream sequence is defined; never use alone to skip events.';
COMMENT ON TABLE sync_inbox_aggregate_cursors IS
  'Per-source aggregate processing cursor. A version is completed only after its business effects commit in the same transaction.';
COMMENT ON FUNCTION claim_sync_outbox(varchar, integer, integer) IS
  'Claims due events with SKIP LOCKED, per-aggregate head-of-line ordering, lease recovery, and fencing token.';
COMMENT ON FUNCTION ack_sync_outbox(uuid, uuid, integer, jsonb) IS
  'Marks an outbox event sent only for the current unexpired claim token after receiver ACK.';
COMMENT ON FUNCTION claim_sync_inbox(varchar, integer, integer) IS
  'Claims only the next aggregate version. Caller must apply business effects and complete inbox in the same DB transaction.';

COMMIT;
