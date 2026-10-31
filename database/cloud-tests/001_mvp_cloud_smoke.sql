-- Cloud MVP schema smoke test. Run after database/cloud-migrations/001_mvp_cloud_schema.sql.
BEGIN;

DO $$
DECLARE
    v_store uuid := '10000000-0000-0000-0000-000000000001';
    v_node uuid := '20000000-0000-0000-0000-000000000001';
    v_sale uuid;
    v_event uuid := '30000000-0000-0000-0000-000000000001';
    v_second_store uuid := '11000000-0000-0000-0000-000000000001';
    v_count bigint;
BEGIN
    INSERT INTO cloud.stores(id, store_code, store_name)
    VALUES (v_store, 'MVP01', 'MVP Test Store');

    INSERT INTO cloud.sync_nodes(id, store_id, node_code)
    VALUES (v_node, v_store, 'MVP01-SRV01');

    INSERT INTO cloud.node_credentials(node_id, client_id, client_secret_hash)
    VALUES (v_node, 'mvp-client-01', '$argon2id$test-only-placeholder-hash-for-schema');

    INSERT INTO cloud.products(id, sku, product_name, barcode)
    VALUES ('40000000-0000-0000-0000-000000000001', 'SKU-001', 'Test Product', '899000000001');

    INSERT INTO cloud.product_prices(product_id, price, valid_from, version)
    VALUES ('40000000-0000-0000-0000-000000000001', 12500, now() - interval '1 day', 1);

    INSERT INTO cloud.payment_methods(code, display_name)
    VALUES ('CASH', 'Tunai');

    INSERT INTO ingest.event_registry(
        source_node_id, source_store_id, event_id, idempotency_key,
        aggregate_type, aggregate_id, aggregate_version, event_type,
        schema_version, payload, payload_sha256, occurred_at
    ) VALUES (
        v_node, v_store, v_event, 'sale-paid-test-001',
        'sale', '50000000-0000-0000-0000-000000000001', 1, 'sale.paid',
        1, '{"test":true}'::jsonb, decode(repeat('a',64),'hex'), now()
    );

    INSERT INTO replica.sales(
        source_store_id, source_node_id, source_sale_id, source_terminal_id,
        source_cashier_id, receipt_number, business_date, currency_code,
        subtotal, discount_total, tax_total, rounding_amount, grand_total, paid_at
    ) VALUES (
        v_store, v_node, '50000000-0000-0000-0000-000000000001',
        '60000000-0000-0000-0000-000000000001',
        '70000000-0000-0000-0000-000000000001',
        'MVP01-20261031-POS01-000001', current_date, 'IDR',
        12500, 0, 0, 0, 12500, now()
    ) RETURNING id INTO v_sale;

    INSERT INTO replica.sale_lines(
        sale_id, source_store_id, source_line_id, source_product_id,
        sku_snapshot, name_snapshot, quantity, unit_price, gross_amount,
        discount_amount, tax_rate_snapshot, tax_amount, line_total
    ) VALUES (
        v_sale, v_store, '80000000-0000-0000-0000-000000000001',
        '40000000-0000-0000-0000-000000000001',
        'SKU-001', 'Test Product', 1, 12500, 12500, 0, 0, 0, 12500
    );

    INSERT INTO replica.payments(
        sale_id, source_store_id, source_payment_id, payment_method_code,
        payment_method_name, amount, confirmed_at
    ) VALUES (
        v_sale, v_store, '90000000-0000-0000-0000-000000000001',
        'CASH', 'Tunai', 12500, now()
    );

    PERFORM replica.assert_sale_complete(v_sale);

    UPDATE ingest.event_registry
       SET status = 'processed', processed_at = now()
     WHERE event_id = v_event AND source_node_id = v_node;

    INSERT INTO replica.audit_events(
        source_store_id, source_node_id, source_event_id, action,
        entity_type, entity_id, occurred_at
    ) VALUES (
        v_store, v_node, 'a0000000-0000-0000-0000-000000000001',
        'sale.paid', 'sale', '50000000-0000-0000-0000-000000000001', now()
    );

    SELECT count(*) INTO v_count FROM reporting.v_sales
     WHERE store_id = v_store AND receipt_number = 'MVP01-20261031-POS01-000001';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'reporting view did not return exactly one sale';
    END IF;

    -- Cross-store child linkage must fail even when both stores and nodes exist.
    INSERT INTO cloud.stores(id, store_code, store_name)
    VALUES (v_second_store, 'MVP02', 'Second Test Store');
    BEGIN
        INSERT INTO replica.sale_lines(
            sale_id, source_store_id, source_line_id, sku_snapshot, name_snapshot,
            quantity, unit_price, gross_amount, discount_amount,
            tax_rate_snapshot, tax_amount, line_total
        ) VALUES (
            v_sale, v_second_store, '81000000-0000-0000-0000-000000000001',
            'BAD-SKU', 'Cross tenant attempt', 1, 1, 1, 0, 0, 0, 1
        );
        RAISE EXCEPTION 'cross-store sale line unexpectedly succeeded';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;

    -- Header/line/payment totals are checked before an event can be marked processed.
    UPDATE replica.payments SET amount = 12000 WHERE sale_id = v_sale;
    BEGIN
        PERFORM replica.assert_sale_complete(v_sale);
        RAISE EXCEPTION 'mismatched payment total unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    UPDATE replica.payments SET amount = 12500 WHERE sale_id = v_sale;
    PERFORM replica.assert_sale_complete(v_sale);

    -- Duplicate event identity must be rejected by a unique constraint.
    BEGIN
        INSERT INTO ingest.event_registry(
            source_node_id, source_store_id, event_id, idempotency_key,
            aggregate_type, aggregate_id, aggregate_version, event_type,
            schema_version, payload, payload_sha256, occurred_at
        ) VALUES (
            v_node, v_store, v_event, 'sale-paid-test-duplicate',
            'sale', 'b0000000-0000-0000-0000-000000000001', 1, 'sale.paid',
            1, '{"test":true}'::jsonb, decode(repeat('a',64),'hex'), now()
        );
        RAISE EXCEPTION 'duplicate event identity unexpectedly succeeded';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
