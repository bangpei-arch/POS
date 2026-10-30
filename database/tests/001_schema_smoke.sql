-- POS database smoke tests
-- Run after 001_initial_schema.sql.
-- All fixture data is rolled back at the end.
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO pos, public;

DO $$
DECLARE
  v_store uuid;
  v_user uuid;
  v_terminal uuid;
  v_product uuid;
  v_customer uuid;
  v_payment_cash uuid;
  v_payment_qris uuid;
  v_drawer uuid;
  v_session uuid;
  v_sale uuid;
  v_sale_line uuid;
  v_refund_method uuid;
  v_refund uuid;
  v_node uuid;
  v_event uuid := gen_random_uuid();
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'pos' AND table_type = 'BASE TABLE';
  IF v_count < 55 THEN
    RAISE EXCEPTION 'Expected at least 55 POS tables; found %', v_count;
  END IF;

  IF to_regclass('pos.uq_active_product_barcode') IS NULL
     OR to_regclass('pos.uq_customer_normalized_phone') IS NULL
     OR to_regclass('pos.uq_one_open_session_per_drawer') IS NULL
     OR to_regclass('pos.ix_sync_outbox_due') IS NULL THEN
    RAISE EXCEPTION 'One or more required indexes are missing';
  END IF;

  -- Foreign-key integrity must reject references to missing parent rows.
  BEGIN
    INSERT INTO org_terminals(store_id, code)
    VALUES (gen_random_uuid(), 'INVALID-FK-TERMINAL');
    RAISE EXCEPTION 'Invalid foreign key unexpectedly accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  INSERT INTO org_stores(code, name) VALUES ('TST', 'Test Store')
  RETURNING id INTO v_store;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('TST-CASHIER', 'Test Cashier', 'not-a-real-hash')
  RETURNING id INTO v_user;
  INSERT INTO org_terminals(store_id, code, name)
  VALUES (v_store, 'POS-TST-01', 'Test Terminal')
  RETURNING id INTO v_terminal;
  INSERT INTO md_products(sku, name, base_uom_code)
  VALUES ('TST-001', 'Test Product', 'PCS')
  RETURNING id INTO v_product;

  -- Check constraints must reject a negative product price.
  BEGIN
    INSERT INTO md_product_prices(product_id, price, valid_from, version)
    VALUES (v_product, -1, now(), 999);
    RAISE EXCEPTION 'Negative product price unexpectedly accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO md_customers(name, is_walk_in)
  VALUES ('Umum', true)
  RETURNING id INTO v_customer;

  INSERT INTO md_customers(name, normalized_phone, is_walk_in)
  VALUES ('Test Customer A', '+628111111111', false);
  BEGIN
    INSERT INTO md_customers(name, normalized_phone, is_walk_in)
    VALUES ('Test Customer B', '+628111111111', false);
    RAISE EXCEPTION 'Duplicate customer phone unexpectedly accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  INSERT INTO md_product_barcodes(product_id, barcode)
  VALUES (v_product, '8990000000001');
  BEGIN
    INSERT INTO md_product_barcodes(product_id, barcode)
    VALUES (v_product, '8990000000001');
    RAISE EXCEPTION 'Duplicate active barcode unexpectedly accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  SELECT id INTO v_payment_cash FROM md_payment_methods WHERE code = 'CASH';
  SELECT id INTO v_payment_qris FROM md_payment_methods WHERE code = 'QRIS';
  IF v_payment_cash IS NULL OR v_payment_qris IS NULL THEN
    RAISE EXCEPTION 'Required payment method seed rows are missing';
  END IF;

  INSERT INTO cash_drawers(store_id, terminal_id, fixed_float_amount)
  VALUES (v_store, v_terminal, 200000)
  RETURNING id INTO v_drawer;
  INSERT INTO cash_sessions(
    drawer_id, store_id, terminal_id, cashier_id, opening_counted
  ) VALUES (
    v_drawer, v_store, v_terminal, v_user, 200000
  ) RETURNING id INTO v_session;

  BEGIN
    INSERT INTO cash_sessions(
      drawer_id, store_id, terminal_id, cashier_id, opening_counted
    ) VALUES (v_drawer, v_store, v_terminal, v_user, 0);
    RAISE EXCEPTION 'Second open session unexpectedly accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, customer_id,
    business_date, status, subtotal, grand_total
  ) VALUES (
    'TST-20261030-POS01-000001', v_store, v_terminal, v_user, v_customer,
    DATE '2026-10-30', 'draft', 100000, 100000
  ) RETURNING id INTO v_sale;

  INSERT INTO pos_sale_lines(
    sale_id, product_id, sku_snapshot, name_snapshot, quantity,
    unit_price, gross_amount, taxable_base, line_total
  ) VALUES (
    v_sale, v_product, 'TST-001', 'Test Product', 2,
    50000, 100000, 100000, 100000
  ) RETURNING id INTO v_sale_line;

  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES
    (v_sale, v_payment_cash, 40000, 'confirmed', now()),
    (v_sale, v_payment_qris, 60000, 'confirmed', now());

  SELECT COALESCE(sum(amount), 0) INTO v_count
  FROM pos_payments
  WHERE sale_id = v_sale AND status = 'confirmed';
  IF v_count <> 100000 THEN
    RAISE EXCEPTION 'Split payment total mismatch: expected 100000, got %', v_count;
  END IF;

  UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;
  IF NOT EXISTS (SELECT 1 FROM pos_sales WHERE id = v_sale AND status = 'paid' AND paid_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Sale could not be finalized as paid';
  END IF;

  INSERT INTO cash_ledger_entries(
    drawer_id, session_id, entry_type, direction, amount,
    source_type, source_id, idempotency_key, actor_id
  ) VALUES (
    v_drawer, v_session, 'sale_payment', 'in', 40000,
    'sale', v_sale, 'test-cash-' || v_sale::text, v_user
  );

  UPDATE cash_sessions
  SET status = 'closed', closing_counted = 240000,
      expected_cash = 240000, variance_amount = 0, closed_at = now()
  WHERE id = v_session;
  IF NOT EXISTS (SELECT 1 FROM cash_sessions WHERE id = v_session AND status = 'closed') THEN
    RAISE EXCEPTION 'Cash session did not close';
  END IF;

  SELECT id INTO v_refund_method FROM md_payment_methods WHERE code = 'CASH';
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status
  ) VALUES (
    v_sale, v_store, v_terminal, v_user, v_refund_method,
    'Smoke test refund', 50000, 'approved'
  ) RETURNING id INTO v_refund;
  INSERT INTO pos_refund_lines(
    refund_id, original_sale_line_id, quantity, refund_amount,
    item_received, item_resalable
  ) VALUES (v_refund, v_sale_line, 1, 50000, true, true);
  UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund;

  IF NOT EXISTS (
    SELECT 1 FROM pos_refund_lines
    WHERE refund_id = v_refund AND stock_return_eligible = true
  ) THEN
    RAISE EXCEPTION 'Eligible physical return was not marked for stock return';
  END IF;

  INSERT INTO sync_nodes(node_type, node_code, store_id)
  VALUES ('store_server', 'TST-NODE', v_store)
  RETURNING id INTO v_node;
  INSERT INTO sync_outbox(
    node_id, event_id, aggregate_type, aggregate_id, event_type, payload
  ) VALUES (
    v_node, v_event, 'sale', v_sale, 'sale.paid',
    jsonb_build_object('sale_id', v_sale, 'status', 'paid')
  );
  INSERT INTO sync_inbox(source_node_id, event_id, idempotency_key)
  VALUES (v_node, v_event, 'test-idem-' || v_event::text);

  BEGIN
    INSERT INTO sync_inbox(source_node_id, event_id, idempotency_key)
    VALUES (v_node, v_event, 'test-idem-' || v_event::text);
    RAISE EXCEPTION 'Duplicate inbox event unexpectedly accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  RAISE NOTICE 'PASS: schema, indexes, customer/barcode uniqueness, cash session, split payment, sale paid, refund eligibility, outbox/inbox idempotency';
END $$;

ROLLBACK;
