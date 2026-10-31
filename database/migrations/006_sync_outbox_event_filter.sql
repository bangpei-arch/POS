-- M3: claim only event types the configured sender can deliver.
-- Unsupported outbox events remain pending and do not burn retries or create permanent 4xx noise.
BEGIN;
SET search_path TO pos, public;

CREATE OR REPLACE FUNCTION claim_sync_outbox_for_types(
  p_worker_id varchar(120),
  p_event_types text[],
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
  IF p_event_types IS NULL OR cardinality(p_event_types) = 0
     OR array_position(p_event_types, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'at least one non-null event type is required';
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
    WHERE o.event_type = ANY(p_event_types)
      AND o.attempts < o.max_attempts
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

COMMIT;
