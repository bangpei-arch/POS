-- M3 filtered outbox claim regression test.
-- Requires migrations 001-006. Fixtures are rolled back.
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO pos, public;

DO $$
DECLARE
  v_node uuid;
  v_sale_aggregate uuid := gen_random_uuid();
  v_audit_aggregate uuid := gen_random_uuid();
  v_sale_event uuid := gen_random_uuid();
  v_audit_event uuid := gen_random_uuid();
  v_claim sync_outbox%ROWTYPE;
BEGIN
  INSERT INTO sync_nodes(node_type,node_code)
  VALUES ('central','SYNC009-FILTER') RETURNING id INTO v_node;

  INSERT INTO sync_outbox(node_id,event_id,aggregate_type,aggregate_id,event_type,payload)
  VALUES
    (v_node,v_audit_event,'audit',v_audit_aggregate,'audit.recorded','{"test":true}'),
    (v_node,v_sale_event,'sale',v_sale_aggregate,'sale.paid','{"test":true}');

  SELECT * INTO v_claim
  FROM claim_sync_outbox_for_types('m3-filter-test',ARRAY['sale.paid'],10,120);

  IF v_claim.id IS NULL OR v_claim.event_id <> v_sale_event THEN
    RAISE EXCEPTION 'Filtered claim did not return the sale.paid event';
  END IF;

  IF (SELECT status FROM sync_outbox WHERE event_id=v_audit_event) <> 'pending'
     OR (SELECT attempts FROM sync_outbox WHERE event_id=v_audit_event) <> 0 THEN
    RAISE EXCEPTION 'Unsupported audit event was claimed or consumed an attempt';
  END IF;

  IF NOT ack_sync_outbox(v_claim.id,v_claim.claim_token,200,'{"processed":true}') THEN
    RAISE EXCEPTION 'Filtered sale event could not be ACKed';
  END IF;

  RAISE NOTICE 'M3 OUTBOX FILTER PASS: only configured sale.paid events are claimed';
END;
$$;

ROLLBACK;
