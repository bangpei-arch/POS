-- POS database integrity guard regression tests
-- Run after migrations 001 and 002. All fixture rows are rolled back.
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO pos, public;

DO $$
DECLARE
  v_store uuid;
  v_cashier uuid;
  v_supervisor uuid;
  v_terminal uuid;
  v_product uuid;
  v_cash uuid;
  v_sale uuid;
  v_line uuid;
  v_payment_1 uuid;
  v_payment_2 uuid;
  v_refund_1 uuid;
  v_refund_2 uuid;
  v_refund_3 uuid;
  v_refund_4 uuid;
  v_sale_2 uuid;
  v_line_2 uuid;
  v_refund_a uuid;
  v_refund_b uuid;
  v_confirmed numeric(18,2);
  v_rejected boolean;
BEGIN
  INSERT INTO org_stores(code, name) VALUES ('GUARD03', 'Guard Test Store') RETURNING id INTO v_store;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('GUARD03-CASH', 'Guard Cashier', 'test-only') RETURNING id INTO v_cashier;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('GUARD03-SUP', 'Guard Supervisor', 'test-only') RETURNING id INTO v_supervisor;
  INSERT INTO org_terminals(store_id, code) VALUES (v_store, 'GUARD03-POS') RETURNING id INTO v_terminal;
  INSERT INTO md_products(sku, name, base_uom_code) VALUES ('GUARD03-SKU', 'Guard Product', 'PCS') RETURNING id INTO v_product;
  SELECT id INTO STRICT v_cash FROM md_payment_methods WHERE code = 'CASH';

  -- Payment equality: 50k confirmed cannot mark a 100k sale paid.
  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, business_date,
    status, subtotal, grand_total
  ) VALUES (
    'GUARD03-UNDERPAID', v_store, v_terminal, v_cashier, DATE '2026-10-31',
    'draft', 100000, 100000
  ) RETURNING id INTO v_sale;

  INSERT INTO pos_sale_lines(
    sale_id, product_id, sku_snapshot, name_snapshot, quantity,
    unit_price, gross_amount, taxable_base, line_total
  ) VALUES (
    v_sale, v_product, 'GUARD03-SKU', 'Guard Product', 4,
    25000, 100000, 100000, 100000
  ) RETURNING id INTO v_line;

  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES (v_sale, v_cash, 50000, 'confirmed', now()) RETURNING id INTO v_payment_1;

  v_rejected := false;
  BEGIN
    UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GAP REGRESSION: underpaid sale was allowed to become paid';
  END IF;
  RAISE NOTICE 'PASS: underpaid sale transition rejected';

  -- Direct INSERT as paid is also protected.
  v_rejected := false;
  BEGIN
    INSERT INTO pos_sales(
      receipt_number, store_id, terminal_id, cashier_id, business_date,
      status, subtotal, grand_total, paid_at
    ) VALUES (
      'GUARD03-DIRECT-PAID', v_store, v_terminal, v_cashier, DATE '2026-10-31',
      'paid', 100000, 100000, now()
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Direct insertion of unpaid PAID sale was accepted';
  END IF;

  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES (v_sale, v_cash, 50000, 'confirmed', now()) RETURNING id INTO v_payment_2;
  SELECT sum(amount) INTO v_confirmed
  FROM pos_payments WHERE sale_id = v_sale AND status = 'confirmed';
  IF v_confirmed <> 100000 THEN
    RAISE EXCEPTION 'Expected confirmed payment total 100000, got %', v_confirmed;
  END IF;
  UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;

  -- Once paid, changing a confirmed payment cannot break equality.
  v_rejected := false;
  BEGIN
    UPDATE pos_payments SET amount = 60000 WHERE id = v_payment_2;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Changing paid-sale payment total was accepted';
  END IF;
  RAISE NOTICE 'PASS: exact split payment accepted; post-paid payment mutation rejected';

  -- First partial refund consumes 1 of 4 units and IDR 25,000.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Guard partial refund', 25000, 'approved', NULL
  ) RETURNING id INTO v_refund_1;
  INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
  VALUES (v_refund_1, v_line, 1, 25000);
  UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_1;

  -- Old GAP scenario 1: quantity over original quantity must fail.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Attempt quantity over-refund', 100000, 'approved', NULL
  ) RETURNING id INTO v_refund_2;
  v_rejected := false;
  BEGIN
    INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
    VALUES (v_refund_2, v_line, 4, 100000);
    UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_2;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Cumulative refund quantity above original was accepted';
  END IF;
  RAISE NOTICE 'PASS: cumulative refund quantity overrun rejected';

  -- Old GAP scenario 2: monetary value over line_total must fail.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Attempt amount over-refund', 75001, 'approved', NULL
  ) RETURNING id INTO v_refund_3;
  v_rejected := false;
  BEGIN
    INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
    VALUES (v_refund_3, v_line, 1, 75001);
    UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_3;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Cumulative refund amount above original line_total was accepted';
  END IF;
  RAISE NOTICE 'PASS: cumulative refund amount overrun rejected';

  -- A valid remaining refund of 3 units / IDR 75,000 succeeds.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status, completed_at
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Valid remaining refund', 75000, 'approved', NULL
  ) RETURNING id INTO v_refund_4;
  INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
  VALUES (v_refund_4, v_line, 3, 75000);
  UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_4;

  -- A refund drafted with lines must also be checked when it becomes paid.
  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, business_date,
    status, subtotal, grand_total
  ) VALUES (
    'GUARD03-REFUND-TRANSITION', v_store, v_terminal, v_cashier,
    DATE '2026-10-31', 'draft', 50000, 50000
  ) RETURNING id INTO v_sale_2;
  INSERT INTO pos_sale_lines(
    sale_id, product_id, sku_snapshot, name_snapshot, quantity,
    unit_price, gross_amount, taxable_base, line_total
  ) VALUES (
    v_sale_2, v_product, 'GUARD03-SKU', 'Guard Product', 2,
    25000, 50000, 50000, 50000
  ) RETURNING id INTO v_line_2;
  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES (v_sale_2, v_cash, 50000, 'confirmed', now());
  UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale_2;
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status
  ) VALUES (
    v_sale_2, v_store, v_terminal, v_supervisor, v_cash,
    'Approved refund A', 25000, 'approved'
  ) RETURNING id INTO v_refund_a;
  INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
  VALUES (v_refund_a, v_line_2, 1, 25000);

  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status
  ) VALUES (
    v_sale_2, v_store, v_terminal, v_supervisor, v_cash,
    'Approved refund B', 50000, 'approved'
  ) RETURNING id INTO v_refund_b;
  INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
  VALUES (v_refund_b, v_line_2, 2, 50000);

  v_rejected := false;
  BEGIN
    UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_a;
  UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund_b;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Over-limit approved refund was allowed to transition to paid';
  END IF;
  RAISE NOTICE 'PASS: refund status transition validates existing refund lines';

  RAISE NOTICE 'INTEGRITY GUARDS PASS: all former GAP scenarios are now rejected';
END $$;

ROLLBACK;
