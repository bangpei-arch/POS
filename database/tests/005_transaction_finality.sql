-- POS transaction finality and refund settlement regression tests
-- Run after migrations 001, 002 and 003. All fixtures are rolled back.
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
  v_payment uuid;
  v_refund uuid;
  v_refund_line uuid;
  v_rejected boolean;
BEGIN
  INSERT INTO org_stores(code, name) VALUES ('FINAL05', 'Finality Test Store') RETURNING id INTO v_store;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('FINAL05-CASH', 'Finality Cashier', 'test-only') RETURNING id INTO v_cashier;
  INSERT INTO iam_users(employee_code, full_name, pin_hash)
  VALUES ('FINAL05-SUP', 'Finality Supervisor', 'test-only') RETURNING id INTO v_supervisor;
  INSERT INTO org_terminals(store_id, code) VALUES (v_store, 'FINAL05-POS') RETURNING id INTO v_terminal;
  INSERT INTO md_products(sku, name, base_uom_code) VALUES ('FINAL05-SKU', 'Finality Product', 'PCS') RETURNING id INTO v_product;
  SELECT id INTO STRICT v_cash FROM md_payment_methods WHERE code = 'CASH';

  -- Create all sale details before finalizing payment.
  INSERT INTO pos_sales(
    receipt_number, store_id, terminal_id, cashier_id, business_date,
    status, subtotal, grand_total
  ) VALUES (
    'FINAL05-SALE', v_store, v_terminal, v_cashier, DATE '2026-10-31',
    'draft', 100000, 100000
  ) RETURNING id INTO v_sale;

  INSERT INTO pos_sale_lines(
    sale_id, product_id, sku_snapshot, name_snapshot, quantity,
    unit_price, gross_amount, taxable_base, line_total
  ) VALUES (
    v_sale, v_product, 'FINAL05-SKU', 'Finality Product', 2,
    50000, 100000, 100000, 100000
  ) RETURNING id INTO v_line;

  INSERT INTO pos_payments(sale_id, payment_method_id, amount, status, confirmed_at)
  VALUES (v_sale, v_cash, 100000, 'confirmed', now()) RETURNING id INTO v_payment;
  UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;

  -- Paid sale header cannot be changed or deleted.
  v_rejected := false;
  BEGIN
    UPDATE pos_sales SET status = 'cancelled' WHERE id = v_sale;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid sale status mutation was accepted'; END IF;

  v_rejected := false;
  BEGIN
    DELETE FROM pos_sales WHERE id = v_sale;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid sale deletion was accepted'; END IF;

  -- Sale lines and payments cannot be changed after payment.
  v_rejected := false;
  BEGIN
    UPDATE pos_sale_lines SET quantity = 1 WHERE id = v_line;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid sale line mutation was accepted'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE pos_payments SET amount = 90000 WHERE id = v_payment;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid sale payment mutation was accepted'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO pos_sale_lines(
      sale_id, product_id, sku_snapshot, name_snapshot, quantity,
      unit_price, gross_amount, taxable_base, line_total
    ) VALUES (v_sale, v_product, 'FINAL05-SKU', 'Late Line', 1, 1000, 1000, 1000, 1000);
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Late sale line insert was accepted'; END IF;

  -- Refund without detail cannot become paid.
  INSERT INTO pos_refunds(
    original_sale_id, store_id, terminal_id, processed_by,
    refund_method_id, reason, total_amount, status
  ) VALUES (
    v_sale, v_store, v_terminal, v_supervisor, v_cash,
    'Missing detail probe', 50000, 'approved'
  ) RETURNING id INTO v_refund;

  v_rejected := false;
  BEGIN
    UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Refund without lines became paid'; END IF;

  -- A refund whose detail does not reconcile with header cannot become paid.
  INSERT INTO pos_refund_lines(refund_id, original_sale_line_id, quantity, refund_amount)
  VALUES (v_refund, v_line, 1, 25000) RETURNING id INTO v_refund_line;

  v_rejected := false;
  BEGIN
    UPDATE pos_refunds SET status = 'paid', completed_at = now() WHERE id = v_refund;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Mismatched refund header/detail became paid'; END IF;

  UPDATE pos_refunds SET total_amount = 25000, status = 'paid', completed_at = now()
  WHERE id = v_refund;

  -- Paid refund header and detail are immutable.
  v_rejected := false;
  BEGIN
    UPDATE pos_refunds SET status = 'cancelled' WHERE id = v_refund;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid refund status mutation was accepted'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE pos_refund_lines SET quantity = 2 WHERE id = v_refund_line;
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Paid refund line mutation was accepted'; END IF;

  RAISE NOTICE 'PASS: paid sale header/details/payment are immutable';
  RAISE NOTICE 'PASS: refund without lines or mismatched total cannot become paid';
  RAISE NOTICE 'PASS: paid refund header/details are immutable';
  RAISE NOTICE 'TRANSACTION FINALITY PASS';
END $$;

ROLLBACK;
