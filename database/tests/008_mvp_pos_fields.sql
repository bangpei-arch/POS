-- MVP local POS fields smoke test. Run after migrations 001-005.
BEGIN;
SET search_path TO pos, public;

DO $$
DECLARE
    v_store uuid := gen_random_uuid();
    v_user uuid := gen_random_uuid();
    v_terminal uuid := gen_random_uuid();
    v_drawer uuid := gen_random_uuid();
    v_session uuid := gen_random_uuid();
    v_product uuid := gen_random_uuid();
    v_sale uuid := gen_random_uuid();
    v_payment uuid := gen_random_uuid();
    v_method uuid;
    v_cash_role uuid;
BEGIN
    INSERT INTO org_stores(id, code, name) VALUES (v_store, 'MVP-FIELDS-' || substr(v_store::text,1,8), 'MVP Fields Test');
    INSERT INTO iam_users(id, employee_code, full_name, pin_hash)
    VALUES (v_user, 'MVP-' || substr(v_user::text,1,8), 'MVP Cashier', '$argon2id$test-placeholder-hash');
    INSERT INTO org_terminals(id, store_id, code, name, primary_cashier_id)
    VALUES (v_terminal, v_store, 'POS-MVP', 'MVP Terminal', v_user);
    INSERT INTO cash_drawers(id, store_id, terminal_id, fixed_float_amount)
    VALUES (v_drawer, v_store, v_terminal, 100000);
    INSERT INTO cash_sessions(id, drawer_id, store_id, terminal_id, cashier_id, opening_counted)
    VALUES (v_session, v_drawer, v_store, v_terminal, v_user, 100000);

    INSERT INTO md_products(id, sku, name, base_uom_code)
    VALUES (v_product, 'MVP-' || substr(v_product::text,1,8), 'MVP Product', 'pcs');

    INSERT INTO pos_sales(
        id, receipt_number, store_id, terminal_id, cashier_id, business_date,
        status, currency_code, subtotal, grand_total, cash_session_id, idempotency_key
    ) VALUES (
        v_sale, 'MVP-' || substr(v_sale::text,1,12), v_store, v_terminal, v_user,
        current_date, 'draft', 'IDR', 100, 100, v_session, 'req-' || v_sale::text
    );

    INSERT INTO pos_sale_lines(
        sale_id, product_id, sku_snapshot, name_snapshot, quantity, unit_price,
        gross_amount, taxable_base, tax_rate_snapshot, tax_amount, line_total
    ) VALUES (
        v_sale, v_product, 'MVP-SKU', 'MVP Product', 1, 100, 100, 100, 0, 0, 100
    );

    SELECT id INTO v_cash_role FROM iam_roles WHERE code = 'CASHIER';
    IF v_cash_role IS NULL THEN
        RAISE EXCEPTION 'CASHIER role seed missing';
    END IF;

    SELECT id INTO v_method FROM md_payment_methods WHERE code = 'CASH';
    INSERT INTO pos_payments(
        id, sale_id, payment_method_id, amount, status, confirmed_by, confirmed_at,
        cash_received_amount, change_amount
    ) VALUES (
        v_payment, v_sale, v_method, 100, 'confirmed', v_user, now(), 120, 20
    );

    -- Non-cash payment cannot carry a cash change amount without tendered cash.
    BEGIN
        UPDATE pos_payments SET cash_received_amount = NULL, change_amount = 1
        WHERE id = v_payment;
        RAISE EXCEPTION 'invalid cash change unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    UPDATE pos_sales SET status = 'paid', paid_at = now() WHERE id = v_sale;

    IF (SELECT change_amount FROM pos_payments WHERE id = v_payment) <> 20 THEN
        RAISE EXCEPTION 'Cash change calculation was not persisted';
    END IF;

    -- Duplicate idempotency key must be rejected.
    BEGIN
        INSERT INTO pos_sales(
            receipt_number, store_id, terminal_id, cashier_id, business_date,
            currency_code, cash_session_id, idempotency_key
        ) VALUES (
            'DUP-' || substr(v_sale::text,1,12), v_store, v_terminal, v_user,
            current_date, 'IDR', v_session, 'req-' || v_sale::text
        );
        RAISE EXCEPTION 'duplicate sale idempotency key unexpectedly succeeded';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;

END;
$$;

ROLLBACK;
