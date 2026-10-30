-- POS integrity and transaction audit suite
-- Run after 001_initial_schema.sql on a disposable development database.
-- All fixture rows are rolled back. This suite tests schema-enforced behavior
-- and explicitly reports business invariants that the current DDL does not enforce.
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO pos, public;

\echo '=== FOREIGN KEY INVENTORY ==='
SELECT conrelid::regclass AS table_name, conname AS constraint_name,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'pos'::regnamespace
ORDER BY conrelid::regclass::text, conname;

\echo '=== CONSTRAINT INVENTORY ==='
SELECT conrelid::regclass AS table_name, conname AS constraint_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE'
         WHEN 'c' THEN 'CHECK' WHEN 'f' THEN 'FOREIGN KEY' ELSE contype::text END AS type,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE connamespace = 'pos'::regnamespace
ORDER BY conrelid::regclass::text, contype, conname;

\echo '=== INDEX INVENTORY ==='
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'pos'
ORDER BY tablename, indexname;

DO $$
DECLARE
  v_store uuid;
  v_user uuid;
  v_supervisor uuid;
  v_terminal uuid;
  v_product uuid;
  v_customer uuid;
  v_cash uuid;
  v_qris uuid;
  v_transfer uuid;
  v_drawer uuid;
  v_session uuid;
  v_sale uuid;
  v_line uuid;
  v_refund_partial uuid;
  v_refund_full uuid;
  v_node uuid;
  v_event uuid := gen_random_uuid();
  v_payment_sum numeric(18,2);
  v_refund_qty integer;
  v_refund_sum numeric(18,2);
  v_cash_expected numeric(18,2);
  v_fk_count integer;
  v_check_count integer;
  v_unique_count integer;
  v_index_count integer;
  v_gap_paid_mismatch boolean := false;
  v_gap_over_refund boolean := false;
  v_gap_cash_source_duplicate boolean := false;
BEGIN
  -- Catalog-level minimums: fail if core referential/integrity objects vanished.
  SELECT count(*) INTO v_fk_count
  FROM pg_constraint WHERE contype = 'f' AND connamespace = 'pos'::regnamespace;
  SELECT count(*) INTO v_check_count
  FROM pg_constraint WHERE contype = 'c' AND connamespace = 'pos'::regnamespace;
  SELECT count(*) INTO v_unique_count
  FROM pg_constraint WHERE contype = 'u' AND connamespace = 'pos'::regnamespace;
  SELECT count(*) INTO v_index_count
  FROM pg_indexes WHERE schemaname = 'pos';

  IF v_fk_count < 50 THEN
    RAISE EXCEPTION 'Foreign-key inventory unexpectedly low: %', v_fk_count;
  END IF;
  IF v_check_count < 20 THEN
    RAISE EXCEPTION 'CHECK constraint inventory unexpectedly low: %', v_check_count;
  END IF;
  IF v_index_count < 70 THEN
    RAISE EXCEPTION 'Index inventory unexpectedly low: %', v_index_count;
  END IF;
  RAISE NOTICE 'CATALOG PASS: % foreign keys, % CHECK constraints, % UNIQUE constraints, % indexes',
    v_fk_count, v_check_count, v_unique_count, v_index_count;

  INSERT INTO org_stores(code, name) VALUES ('AUDIT02', 'Integrity Audit Store')
  RETURNING id INTO v_store;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('AUDIT-CASHIER', 'Audit Cashier', 'test-only')
  RETURNING id INTO v_user;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('AUDIT-SUPERVISOR', 'Audit Supervisor', 'test-only')
  RETURNING id INTO v_supervisor;
  INSERT INTO org_terminals(store_id, code, name)
  VALUES (v_store, 'AUDIT-POS-01', 'Audit Terminal')
  RETURNING id INTO v_terminal;
  INSERT INTO md_products(sku, name, base_uom_code)
  VALUES ('AUDIT-SKU-01', 'Audit Product', 'PCS')
  RETURNING id INTO v_product;
  INSERT INTO md_customers(name, normalized_phone, is_walk_in)
  VALUES ('Audit Customer', '+6281999990001', false)
  RETURNING id INTO v_customer;

  SELECT id INTO STRICT v_cash FROM md_payment_methods WHERE code = 'CASH';
  SELECT id INTO STRICT v_qris FROM md_payment_methods WHERE code = 'QRIS';
  SELECT id INTO STRICT v_transfer FROM md_payment_methods WHERE code = 'TRANSFER';

  INSERT INTO cash_drawers(store_id, terminal_id, fixed_float_amount)
  VALUES (v_store, v_terminal, 200000)
  RETURNING id INTO v_drawer;
  INSERT INTO cash_sessions(drawer_id, store_id, terminal_id, cashier_id, opening_counted)
  VALUES (v_drawer, v_store, v_terminal, v_user, 200000)
  RETURNING id INTO v_session;

  -- One sale, paid with three tenders: cash + QRIS + transfer.
  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, customer_id,
    business_date, status, subtotal, grand_total
  ) VALUES (
    'AUDIT02-20261031-POS01-000001', v_store, v_terminal, v_user, v_customer,
    DATE '2026-10-31', 'draft', 100000, 100000
  ) RETURNING id INTO v_sale;

  INSERT INTO pos_sale_lines(
    sale_id, product_id, sku_snapshot, name_snapshot, quantity,
    unit_price, gross_amount, taxable_base, line_total
  ) VALUES (
    v_sale, v_product, 'AUDIT-SKU-01', 'Audit Product', 4,
    25000, 100000, 100000, 100000
  ) RETURNING id INTO v_line;

  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at, confirmed_by)
  VALUES
    (v_sale, v_cash, 40000, 'confirmed', now(), v_supervisor),
    (v_sale, v_qris, 30000, 'confirmed', now(), v_supervisor),
    (v_sale, v_transfer, 30000, 'confirmed', now(), v_supervisor);

  SELECT COALESCE(sum(amount),0) INTO v_payment_sum
  FROM pos_payments WHERE sale_id = v_sale AND status = 'confirmed';
  IF v_payment_sum <> 100000 THEN
    RAISE EXCEPTION 'Split tender total mismatch: %', v_payment_sum;
  END IF;
  UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;
  RAISE NOTICE 'PASS: three-method split tender totals IDR %', v_payment_sum;

  -- Refund 1: partial return of one item, physically received and resalable.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Partial refund audit', 25000, 'paid', now()
  ) RETURNING id INTO v_refund_partial;
  INSERT INTO pos_refund_lines(
    refund_id, original_sale_line_id, quantity, refund_amount,
    item_received, item_resalable
  ) VALUES (v_refund_partial, v_line, 1, 25000, true, true);

  -- Refund 2: remaining three items; physically received but not resalable.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Remaining quantity refund audit', 75000, 'paid', now()
  ) RETURNING id INTO v_refund_full;
  INSERT INTO pos_refund_lines(
    refund_id, original_sale_line_id, quantity, refund_amount,
    item_received, item_resalable
  ) VALUES (v_refund_full, v_line, 3, 75000, true, false);

  SELECT sum(quantity), sum(refund_amount)
  INTO v_refund_qty, v_refund_sum
  FROM pos_refund_lines
  WHERE original_sale_line_id = v_line;
  IF v_refund_qty <> 4 OR v_refund_sum <> 100000 THEN
    RAISE EXCEPTION 'Partial/full refund totals mismatch: qty %, amount %', v_refund_qty, v_refund_sum;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pos_refund_lines
    WHERE refund_id = v_refund_partial AND stock_return_eligible
  ) THEN
    RAISE EXCEPTION 'Resalable received item was not stock-return eligible';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pos_refund_lines
    WHERE refund_id = v_refund_full AND stock_return_eligible
  ) THEN
    RAISE EXCEPTION 'Non-resalable refund line incorrectly marked stock-return eligible';
  END IF;
  RAISE NOTICE 'PASS: partial + remaining refund totals IDR %, quantity %; stock eligibility matches item condition',
    v_refund_sum, v_refund_qty;

  -- Check whether the database itself blocks cumulative over-refund.
  BEGIN
    INSERT INTO pos_refund_lines(
      refund_id, original_sale_line_id, quantity, refund_amount,
      item_received, item_resalable
    ) VALUES (v_refund_full, v_line, 1, 25000, false, false);
    v_gap_over_refund := true;
    DELETE FROM pos_refund_lines
    WHERE refund_id = v_refund_full AND original_sale_line_id = v_line
      AND quantity = 1 AND refund_amount = 25000;
  EXCEPTION WHEN check_violation OR unique_violation THEN
    NULL;
  END;

  -- Cash movement: sale cash 40k + cash-in 10k - cash-out 5k - cash refund 25k.
  INSERT INTO cash_ledger_entries(
    drawer_id, session_id, entry_type, direction, amount,
    source_type, source_id, idempotency_key, actor_id
  ) VALUES
    (v_drawer, v_session, 'sale_payment', 'in', 40000, 'sale', v_sale, 'audit02-sale-' || v_sale::text, v_user),
    (v_drawer, v_session, 'cash_in', 'in', 10000, 'manual', gen_random_uuid(), 'audit02-in-' || v_sale::text, v_supervisor),
    (v_drawer, v_session, 'cash_out', 'out', 5000, 'manual', gen_random_uuid(), 'audit02-out-' || v_sale::text, v_supervisor),
    (v_drawer, v_session, 'refund', 'out', 25000, 'refund', v_refund_partial, 'audit02-refund-' || v_sale::text, v_supervisor);

  SELECT 200000 + COALESCE(sum(
    CASE direction WHEN 'in' THEN amount ELSE -amount END
  ),0) INTO v_cash_expected
  FROM cash_ledger_entries WHERE session_id = v_session;
  IF v_cash_expected <> 220000 THEN
    RAISE EXCEPTION 'Cash ledger expected balance mismatch: %', v_cash_expected;
  END IF;

  -- Duplicate ledger idempotency key must be rejected.
  BEGIN
    INSERT INTO cash_ledger_entries(
      drawer_id, session_id, entry_type, direction, amount,
      idempotency_key, actor_id
    ) VALUES (
      v_drawer, v_session, 'cash_in', 'in', 10000,
      'audit02-in-' || v_sale::text, v_supervisor
    );
    RAISE EXCEPTION 'Duplicate cash ledger idempotency key was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Close with an actual count 2,000 below expected: variance must be retained.
  UPDATE cash_sessions
  SET status = 'closed', closing_counted = 218000,
      expected_cash = v_cash_expected,
      variance_amount = 218000 - v_cash_expected,
      closed_at = now()
  WHERE id = v_session;
  IF NOT EXISTS (
    SELECT 1 FROM cash_sessions
    WHERE id = v_session AND status = 'closed'
      AND expected_cash = 220000 AND variance_amount = -2000
  ) THEN
    RAISE EXCEPTION 'Cash session closing variance was not stored correctly';
  END IF;
  RAISE NOTICE 'PASS: cash in/out/refund ledger; expected IDR %, actual IDR 218000, variance IDR -2000',
    v_cash_expected;

  -- Outbox retry: failed delivery can be retried without creating a new event.
  INSERT INTO sync_nodes(node_type, node_code, store_id)
  VALUES ('store_server', 'AUDIT02-NODE', v_store)
  RETURNING id INTO v_node;
  INSERT INTO sync_outbox(
    node_id, event_id, aggregate_type, aggregate_id, event_type, payload,
    status, attempts, last_error
  ) VALUES (
    v_node, v_event, 'sale', v_sale, 'sale.paid',
    jsonb_build_object('sale_id', v_sale, 'status', 'paid'),
    'failed', 1, 'simulated first delivery failure'
  );
  INSERT INTO sync_delivery_attempts(outbox_id, result, response_code, error_message)
  SELECT id, 'failed', 503, 'simulated unavailable central' FROM sync_outbox WHERE event_id = v_event;
  UPDATE sync_outbox
  SET status = 'pending', attempts = attempts + 1, next_retry_at = now(), last_error = NULL
  WHERE event_id = v_event;
  UPDATE sync_outbox
  SET status = 'sent', sent_at = now()
  WHERE event_id = v_event AND status = 'pending';
  IF NOT EXISTS (
    SELECT 1 FROM sync_outbox WHERE event_id = v_event
      AND status = 'sent' AND attempts = 2 AND sent_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Outbox retry lifecycle failed';
  END IF;

  INSERT INTO sync_inbox(source_node_id, event_id, idempotency_key, processing_status)
  VALUES (v_node, v_event, 'audit02-idem-' || v_event::text, 'processed')
  ON CONFLICT DO NOTHING;
  -- Simulate redelivery of the exact event: conflict must not create a second inbox row.
  INSERT INTO sync_inbox(source_node_id, event_id, idempotency_key, processing_status)
  VALUES (v_node, v_event, 'audit02-idem-' || v_event::text, 'received')
  ON CONFLICT DO NOTHING;
  IF (SELECT count(*) FROM sync_inbox WHERE source_node_id = v_node AND event_id = v_event) <> 1 THEN
    RAISE EXCEPTION 'Duplicate inbox delivery created more than one event';
  END IF;
  IF (SELECT processing_status FROM sync_inbox WHERE source_node_id = v_node AND event_id = v_event) <> 'processed' THEN
    RAISE EXCEPTION 'Duplicate delivery changed the processed inbox state';
  END IF;
  RAISE NOTICE 'PASS: outbox retry, delivery attempt history, inbox duplicate delivery idempotency';

  -- The current DDL permits a paid sale with confirmed payments below grand_total.
  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, business_date,
    status, subtotal, grand_total, paid_at
  ) VALUES (
    'AUDIT02-PAID-MISMATCH', v_store, v_terminal, v_user, DATE '2026-10-31',
    'paid', 100000, 100000, now()
  ) RETURNING id INTO v_sale;
  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES (v_sale, v_cash, 50000, 'confirmed', now());
  SELECT COALESCE(sum(amount),0) INTO v_payment_sum
  FROM pos_payments WHERE sale_id = v_sale AND status = 'confirmed';
  v_gap_paid_mismatch := (v_payment_sum <> 100000);

  IF v_gap_paid_mismatch THEN
    RAISE NOTICE 'GAP: current DDL permits PAID sale with confirmed payments IDR % below grand_total IDR 100000; enforce in transactional service or database trigger';
  END IF;
  IF v_gap_over_refund THEN
    RAISE NOTICE 'GAP: current DDL permits cumulative refund quantity/value above original sale line; enforce atomically in refund service or database trigger';
  END IF;

  RAISE NOTICE 'AUDIT PASS: structural catalog and scenario assertions completed; review GAP notices before production';
END $$;

ROLLBACK;
