-- Cloud POS MVP schema, separate database from store-local POS database.
-- Target: PostgreSQL 16+
-- NEW CLOUD DATABASE ONLY. Never run against store-local POS DB.
-- MVP: master bootstrap + sale.paid ingestion + central reporting.
BEGIN;

CREATE SCHEMA IF NOT EXISTS cloud;
CREATE SCHEMA IF NOT EXISTS ingest;
CREATE SCHEMA IF NOT EXISTS replica;
CREATE SCHEMA IF NOT EXISTS reporting;

CREATE TABLE cloud.stores (
    id uuid PRIMARY KEY,
    store_code varchar(20) NOT NULL UNIQUE,
    store_name varchar(160) NOT NULL,
    timezone varchar(64) NOT NULL DEFAULT 'Asia/Jakarta',
    currency_code char(3) NOT NULL DEFAULT 'IDR',
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_cloud_stores_currency CHECK (currency_code ~ '^[A-Z]{3}$')
);

-- Store server is the only cloud sync principal in MVP. Terminals have no cloud credentials.
CREATE TABLE cloud.sync_nodes (
    id uuid PRIMARY KEY,
    store_id uuid NOT NULL REFERENCES cloud.stores(id) ON DELETE RESTRICT,
    node_code varchar(60) NOT NULL UNIQUE,
    node_type varchar(20) NOT NULL DEFAULT 'store_server',
    status varchar(20) NOT NULL DEFAULT 'active',
    app_version varchar(40),
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz,
    CONSTRAINT uq_cloud_sync_nodes_id_store UNIQUE (id, store_id),
    CONSTRAINT ck_cloud_sync_nodes_type CHECK (node_type = 'store_server'),
    CONSTRAINT ck_cloud_sync_nodes_status CHECK (status IN ('active','disabled','revoked'))
);
CREATE INDEX ix_cloud_sync_nodes_store_status ON cloud.sync_nodes(store_id, status);

CREATE TABLE cloud.node_credentials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id uuid NOT NULL REFERENCES cloud.sync_nodes(id) ON DELETE RESTRICT,
    client_id varchar(100) NOT NULL UNIQUE,
    client_secret_hash text NOT NULL,
    scopes text[] NOT NULL DEFAULT ARRAY['sync:events:write','sync:master:read','sync:heartbeat:write']::text[],
    credential_version integer NOT NULL DEFAULT 1,
    valid_from timestamptz NOT NULL DEFAULT now(),
    valid_until timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_cloud_node_credentials_hash CHECK (length(client_secret_hash) >= 20),
    CONSTRAINT ck_cloud_node_credentials_version CHECK (credential_version > 0),
    CONSTRAINT ck_cloud_node_credentials_dates CHECK (
        (valid_until IS NULL OR valid_until > valid_from)
        AND (revoked_at IS NULL OR revoked_at >= valid_from)
    )
);
CREATE UNIQUE INDEX uq_cloud_node_one_current_credential
    ON cloud.node_credentials(node_id)
    WHERE revoked_at IS NULL AND valid_until IS NULL;
CREATE INDEX ix_cloud_node_credentials_node ON cloud.node_credentials(node_id, valid_from DESC);

-- Minimal cloud-owned master for the MVP bootstrap response.
CREATE TABLE cloud.products (
    id uuid PRIMARY KEY,
    sku varchar(50) NOT NULL UNIQUE,
    product_name varchar(200) NOT NULL,
    barcode varchar(100),
    is_active boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_cloud_products_barcode
    ON cloud.products(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX ix_cloud_products_active_name ON cloud.products(product_name) WHERE is_active;

CREATE TABLE cloud.product_prices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id uuid NOT NULL REFERENCES cloud.products(id) ON DELETE RESTRICT,
    price numeric(18,2) NOT NULL,
    valid_from timestamptz NOT NULL,
    valid_until timestamptz,
    version bigint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_cloud_product_prices_version UNIQUE(product_id, version),
    CONSTRAINT ck_cloud_product_prices_amount CHECK(price >= 0),
    CONSTRAINT ck_cloud_product_prices_version CHECK(version > 0),
    CONSTRAINT ck_cloud_product_prices_dates CHECK(valid_until IS NULL OR valid_until > valid_from)
);
CREATE INDEX ix_cloud_product_prices_current ON cloud.product_prices(product_id, valid_from DESC);

CREATE TABLE cloud.payment_methods (
    code varchar(30) PRIMARY KEY,
    display_name varchar(80) NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    requires_manual_confirmation boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Dedupe registry is retained after raw payload purge. Do not partition this table in MVP.
CREATE TABLE ingest.event_registry (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_node_id uuid NOT NULL,
    source_store_id uuid NOT NULL,
    event_id uuid NOT NULL,
    idempotency_key varchar(140) NOT NULL,
    aggregate_type varchar(60) NOT NULL,
    aggregate_id uuid NOT NULL,
    aggregate_version bigint NOT NULL,
    event_type varchar(80) NOT NULL,
    schema_version integer NOT NULL DEFAULT 1,
    payload jsonb,
    payload_sha256 bytea NOT NULL,
    occurred_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    status varchar(20) NOT NULL DEFAULT 'received',
    error_code varchar(80),
    CONSTRAINT fk_event_registry_node_store
        FOREIGN KEY(source_node_id, source_store_id)
        REFERENCES cloud.sync_nodes(id, store_id) ON DELETE RESTRICT,
    CONSTRAINT uq_event_registry_event UNIQUE(source_node_id, event_id),
    CONSTRAINT uq_event_registry_idempotency UNIQUE(source_node_id, idempotency_key),
    CONSTRAINT uq_event_registry_aggregate_version
        UNIQUE(source_node_id, aggregate_type, aggregate_id, aggregate_version),
    CONSTRAINT ck_event_registry_version CHECK(aggregate_version > 0 AND schema_version > 0),
    CONSTRAINT ck_event_registry_hash CHECK(octet_length(payload_sha256) = 32),
    CONSTRAINT ck_event_registry_payload CHECK(payload IS NULL OR jsonb_typeof(payload) = 'object'),
    CONSTRAINT ck_event_registry_status CHECK(status IN ('received','processed','rejected'))
);
CREATE INDEX ix_event_registry_retention ON ingest.event_registry(status, received_at);
CREATE INDEX ix_event_registry_aggregate ON ingest.event_registry(source_node_id, aggregate_type, aggregate_id, aggregate_version);

CREATE TABLE replica.sales (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_store_id uuid NOT NULL REFERENCES cloud.stores(id) ON DELETE RESTRICT,
    source_node_id uuid NOT NULL,
    source_sale_id uuid NOT NULL,
    source_terminal_id uuid NOT NULL,
    source_cashier_id uuid NOT NULL,
    receipt_number varchar(80) NOT NULL,
    business_date date NOT NULL,
    currency_code char(3) NOT NULL,
    subtotal numeric(18,2) NOT NULL,
    discount_total numeric(18,2) NOT NULL DEFAULT 0,
    tax_total numeric(18,2) NOT NULL DEFAULT 0,
    rounding_amount numeric(18,2) NOT NULL DEFAULT 0,
    grand_total numeric(18,2) NOT NULL,
    paid_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_replica_sales_node_store
        FOREIGN KEY(source_node_id, source_store_id)
        REFERENCES cloud.sync_nodes(id, store_id) ON DELETE RESTRICT,
    CONSTRAINT uq_replica_sales_source UNIQUE(source_store_id, source_sale_id),
    CONSTRAINT uq_replica_sales_receipt UNIQUE(source_store_id, receipt_number),
    CONSTRAINT uq_replica_sales_id_store UNIQUE(id, source_store_id),
    CONSTRAINT ck_replica_sales_totals CHECK(
        subtotal >= 0 AND discount_total >= 0 AND tax_total >= 0 AND grand_total >= 0
    ),
    CONSTRAINT ck_replica_sales_currency CHECK(currency_code ~ '^[A-Z]{3}$')
);
CREATE INDEX ix_replica_sales_store_date ON replica.sales(source_store_id, business_date DESC);
CREATE INDEX ix_replica_sales_paid_at ON replica.sales(paid_at DESC);

CREATE TABLE replica.sale_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sale_id uuid NOT NULL,
    source_store_id uuid NOT NULL,
    source_line_id uuid NOT NULL,
    source_product_id uuid,
    sku_snapshot varchar(50) NOT NULL,
    name_snapshot varchar(200) NOT NULL,
    barcode_snapshot varchar(100),
    quantity integer NOT NULL,
    unit_price numeric(18,2) NOT NULL,
    gross_amount numeric(18,2) NOT NULL,
    discount_amount numeric(18,2) NOT NULL DEFAULT 0,
    tax_code_snapshot varchar(30),
    tax_rate_snapshot numeric(7,4) NOT NULL DEFAULT 0,
    tax_amount numeric(18,2) NOT NULL DEFAULT 0,
    line_total numeric(18,2) NOT NULL,
    CONSTRAINT fk_replica_sale_lines_sale
        FOREIGN KEY(sale_id, source_store_id)
        REFERENCES replica.sales(id, source_store_id) ON DELETE RESTRICT,
    CONSTRAINT uq_replica_sale_lines_source UNIQUE(source_store_id, source_line_id),
    CONSTRAINT ck_replica_sale_lines_quantity CHECK(quantity > 0),
    CONSTRAINT ck_replica_sale_lines_amounts CHECK(
        unit_price >= 0 AND gross_amount >= 0 AND discount_amount >= 0
        AND tax_rate_snapshot BETWEEN 0 AND 100 AND tax_amount >= 0 AND line_total >= 0
    )
);
CREATE INDEX ix_replica_sale_lines_sale ON replica.sale_lines(sale_id);
CREATE INDEX ix_replica_sale_lines_sku ON replica.sale_lines(sku_snapshot);

CREATE TABLE replica.payments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sale_id uuid NOT NULL,
    source_store_id uuid NOT NULL,
    source_payment_id uuid NOT NULL,
    payment_method_code varchar(30) NOT NULL,
    payment_method_name varchar(80) NOT NULL,
    amount numeric(18,2) NOT NULL,
    reference_number varchar(120),
    confirmed_at timestamptz NOT NULL,
    CONSTRAINT fk_replica_payments_sale
        FOREIGN KEY(sale_id, source_store_id)
        REFERENCES replica.sales(id, source_store_id) ON DELETE RESTRICT,
    CONSTRAINT uq_replica_payments_source UNIQUE(source_store_id, source_payment_id),
    CONSTRAINT ck_replica_payments_amount CHECK(amount > 0)
);
CREATE INDEX ix_replica_payments_sale ON replica.payments(sale_id);
CREATE INDEX ix_replica_payments_method_time ON replica.payments(payment_method_code, confirmed_at DESC);

CREATE TABLE replica.audit_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_store_id uuid NOT NULL REFERENCES cloud.stores(id) ON DELETE RESTRICT,
    source_node_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    source_actor_id uuid,
    source_terminal_id uuid,
    action varchar(80) NOT NULL,
    entity_type varchar(60) NOT NULL,
    entity_id uuid,
    reason text,
    correlation_id uuid,
    occurred_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_replica_audit_node_store
        FOREIGN KEY(source_node_id, source_store_id)
        REFERENCES cloud.sync_nodes(id, store_id) ON DELETE RESTRICT,
    CONSTRAINT uq_replica_audit_source UNIQUE(source_store_id, source_event_id),
    CONSTRAINT ck_replica_audit_action CHECK(action IN (
        'auth.login_failed','cash_session.opened','cash_session.closed',
        'sale.payment_confirmed','sale.paid','receipt.reprinted','sync.delivery_failed'
    ))
);
CREATE INDEX ix_replica_audit_store_time ON replica.audit_events(source_store_id, occurred_at DESC);

-- Receiver MUST call this after inserting sale header, lines, and confirmed payments,
-- and before marking the event processed. Aggregate checks cannot be expressed as CHECK constraints.
CREATE FUNCTION replica.assert_sale_complete(p_sale_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $
DECLARE
    v_grand_total numeric(18,2);
    v_line_total numeric(18,2);
    v_payment_total numeric(18,2);
    v_line_count bigint;
    v_payment_count bigint;
BEGIN
    SELECT grand_total INTO v_grand_total
    FROM replica.sales WHERE id = p_sale_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'sale % not found', p_sale_id USING ERRCODE = '23503';
    END IF;

    SELECT count(*), COALESCE(sum(line_total), 0)
      INTO v_line_count, v_line_total
      FROM replica.sale_lines WHERE sale_id = p_sale_id;

    SELECT count(*), COALESCE(sum(amount), 0)
      INTO v_payment_count, v_payment_total
      FROM replica.payments WHERE sale_id = p_sale_id;

    IF v_line_count < 1 OR v_payment_count < 1 THEN
        RAISE EXCEPTION 'sale % requires at least one line and one confirmed payment', p_sale_id
            USING ERRCODE = '23514';
    END IF;

    IF v_line_total <> v_grand_total OR v_payment_total <> v_grand_total THEN
        RAISE EXCEPTION 'sale % total mismatch: header %, lines %, payments %',
            p_sale_id, v_grand_total, v_line_total, v_payment_total
            USING ERRCODE = '23514';
    END IF;
END;
$;

CREATE VIEW reporting.v_sales AS
SELECT s.source_store_id AS store_id, st.store_code, st.store_name,
       s.business_date, s.receipt_number, s.grand_total, s.currency_code,
       s.paid_at, s.id AS cloud_sale_id
FROM replica.sales s
JOIN cloud.stores st ON st.id = s.source_store_id;

COMMIT;
