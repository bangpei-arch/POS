-- Sync recovery, lease fencing, per-aggregate ordering, and inbox idempotency tests.
-- Requires migrations 001 through 004. All fixtures are rolled back.
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO pos, public;

DO $$
DECLARE
  v_node uuid;
  v_node2 uuid;
  v_aggregate uuid := gen_random_uuid();
  v_event1 uuid := gen_random_uuid();
  v_event2 uuid := gen_random_uuid();
  v_event3 uuid := gen_random_uuid();
  v_event4 uuid := gen_random_uuid();
  v_claim sync_outbox%ROWTYPE;
  v_reclaim sync_outbox%ROWTYPE;
  v_next sync_outbox%ROWTYPE;
  v_inbox1 uuid := gen_random_uuid();
  v_inbox2 uuid := gen_random_uuid();
  v_inbox_claim sync_inbox%ROWTYPE;
  v_inventory uuid := gen_random_uuid();
  v_ok boolean;
BEGIN
  INSERT INTO sync_nodes(node_type, node_code)
  VALUES ('central', 'SYNC004-NODE-1') RETURNING id INTO v_node;
  INSERT INTO sync_nodes(node_type, node_code)
  VALUES ('central', 'SYNC004-NODE-2') RETURNING id INTO v_node2;

  -- Trigger allocates monotonically increasing aggregate versions.
  INSERT INTO sync_outbox(node_id,event_id,aggregate_type,aggregate_id,event_type,payload)
  VALUES
    (v_node,v_event1,'sale',v_aggregate,'sale.created','{"n":1}'),
    (v_node,v_event2,'sale',v_aggregate,'sale.paid','{"n":2}');
  IF (SELECT aggregate_version FROM sync_outbox WHERE event_id=v_event1) <> 1
     OR (SELECT aggregate_version FROM sync_outbox WHERE event_id=v_event2) <> 2 THEN
    RAISE EXCEPTION 'Outbox aggregate versions were not allocated in order';
  END IF;

  -- Head-of-line ordering: only version 1 may be claimed.
  SELECT * INTO v_claim FROM claim_sync_outbox('worker-A', 10, 120);
  IF v_claim.id IS NULL OR v_claim.event_id <> v_event1 THEN
    RAISE EXCEPTION 'Expected aggregate version 1 to be claimed first';
  END IF;
  IF EXISTS (SELECT 1 FROM sync_outbox WHERE event_id=v_event2 AND status='sending') THEN
    RAISE EXCEPTION 'Aggregate version 2 was claimed before version 1 ACK';
  END IF;

  -- Simulate a worker crash. A new worker reclaims after lease expiry.
  UPDATE sync_outbox SET lease_until = now() - interval '1 second'
  WHERE id = v_claim.id;
  SELECT * INTO v_reclaim FROM claim_sync_outbox('worker-B', 1, 120);
  IF v_reclaim.id <> v_claim.id OR v_reclaim.claim_token = v_claim.claim_token THEN
    RAISE EXCEPTION 'Expired lease was not reclaimed with a new fencing token';
  END IF;
  IF ack_sync_outbox(v_claim.id, v_claim.claim_token, 200, '{"ack":true}') THEN
    RAISE EXCEPTION 'Stale worker ACK was accepted';
  END IF;
  IF NOT ack_sync_outbox(v_reclaim.id, v_reclaim.claim_token, 200, '{"ack":true}') THEN
    RAISE EXCEPTION 'Current worker ACK was rejected';
  END IF;
  IF (SELECT status FROM sync_outbox WHERE id=v_claim.id) <> 'sent'
     OR (SELECT acked_at FROM sync_outbox WHERE id=v_claim.id) IS NULL THEN
    RAISE EXCEPTION 'ACK did not persist sent/acked state';
  END IF;

  SELECT * INTO v_next FROM claim_sync_outbox('worker-A', 1, 120);
  IF v_next.event_id <> v_event2 THEN
    RAISE EXCEPTION 'Next aggregate version was not released after ACK';
  END IF;
  IF NOT ack_sync_outbox(v_next.id, v_next.claim_token, 200, '{"ack":true}') THEN
    RAISE EXCEPTION 'Second aggregate event ACK failed';
  END IF;

  -- Permanent failure blocks the next aggregate version; no silent skipping.
  INSERT INTO sync_outbox(node_id,event_id,aggregate_type,aggregate_id,event_type,payload)
  VALUES (v_node,v_event3,'sale',v_aggregate,'sale.refunded','{"n":3}');
  SELECT * INTO v_claim FROM claim_sync_outbox('worker-A', 1, 120);
  IF v_claim.event_id <> v_event3 THEN RAISE EXCEPTION 'Expected version 3'; END IF;
  IF NOT fail_sync_outbox(v_claim.id,v_claim.claim_token,'permanent test error','validation',NULL,true,422) THEN
    RAISE EXCEPTION 'Permanent failure transition failed';
  END IF;
  INSERT INTO sync_outbox(node_id,event_id,aggregate_type,aggregate_id,event_type,payload)
  VALUES (v_node,v_event4,'sale',v_aggregate,'sale.adjusted','{"n":4}');
  SELECT * INTO v_claim FROM claim_sync_outbox('worker-A', 10, 120);
  IF v_claim.id IS NOT NULL THEN
    RAISE EXCEPTION 'Later aggregate event bypassed a failed predecessor';
  END IF;

  -- Inbox ordering: version 2 may arrive first but cannot be claimed before 1.
  INSERT INTO sync_inbox(
    source_node_id,event_id,idempotency_key,aggregate_type,aggregate_id,aggregate_version
  ) VALUES
    (v_node,gen_random_uuid(),'same-key-node-1','sale',v_aggregate,2),
    (v_node,v_inbox1,'inbox-key-1','sale',v_aggregate,1);

  -- Idempotency keys are scoped by source node, not globally across all nodes.
  INSERT INTO sync_inbox(
    source_node_id,event_id,idempotency_key,aggregate_type,aggregate_id,aggregate_version
  ) VALUES (v_node2,gen_random_uuid(),'same-key-node-1','sale',gen_random_uuid(),1);

  SELECT * INTO v_inbox_claim FROM claim_sync_inbox('inbox-worker',10,120);
  IF v_inbox_claim.event_id <> v_inbox1 OR v_inbox_claim.aggregate_version <> 1 THEN
    RAISE EXCEPTION 'Inbox claimed out of aggregate order';
  END IF;
  IF NOT complete_sync_inbox(v_inbox_claim.id,v_inbox_claim.claim_token,'{"accepted":true}') THEN
    RAISE EXCEPTION 'Inbox version 1 completion failed';
  END IF;
  SELECT * INTO v_inbox_claim FROM claim_sync_inbox('inbox-worker',10,120);
  IF v_inbox_claim.aggregate_version <> 2 THEN
    RAISE EXCEPTION 'Inbox version 2 was not released after version 1 commit';
  END IF;
  IF NOT complete_sync_inbox(v_inbox_claim.id,v_inbox_claim.claim_token,'{"accepted":true}') THEN
    RAISE EXCEPTION 'Inbox version 2 completion failed';
  END IF;

  -- Inventory integration queue also recovers a crashed sender using fencing.
  INSERT INTO sync_inventory_events(
    source_type,source_id,event_type,payload,idempotency_key
  ) VALUES ('sale',gen_random_uuid(),'sale.paid','{"qty":1}', 'inv-sync-004')
  RETURNING id INTO v_inventory;
  SELECT * INTO STRICT v_claim
  FROM sync_outbox
  WHERE false;
  -- Use the inventory composite type directly.
  DECLARE
    v_inventory_claim sync_inventory_events%ROWTYPE;
  BEGIN
    SELECT * INTO v_inventory_claim
    FROM claim_sync_inventory_events('inventory-worker',1,120);
    IF v_inventory_claim.id <> v_inventory THEN
      RAISE EXCEPTION 'Inventory event was not claimed';
    END IF;
    UPDATE sync_inventory_events SET lease_until=now()-interval '1 second'
    WHERE id=v_inventory;
    SELECT * INTO v_inventory_claim
    FROM claim_sync_inventory_events('inventory-worker-2',1,120);
    IF NOT ack_sync_inventory_event(v_inventory,v_inventory_claim.claim_token,'{"ok":true}') THEN
      RAISE EXCEPTION 'Inventory event ACK failed after lease recovery';
    END IF;
  END;

  RAISE NOTICE 'SYNC RECOVERY PASS: aggregate ordering, expired lease recovery, stale ACK fencing, failed-event blocking, inbox ordering/idempotency, inventory lease';
END;
$$;

ROLLBACK;
