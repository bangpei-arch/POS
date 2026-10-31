-- MVP Store POS fields: cash session association, request idempotency, cash change.
-- Requires local migrations 001-004. Store-local database only.
BEGIN;
SET search_path TO pos, public;

ALTER TABLE pos_sales
    ADD COLUMN cash_session_id uuid REFERENCES cash_sessions(id) ON DELETE RESTRICT,
    ADD COLUMN idempotency_key varchar(140),
    ADD COLUMN idempotency_hash bytea,
    ADD CONSTRAINT ck_pos_sales_idempotency_pair CHECK (
        (idempotency_key IS NULL AND idempotency_hash IS NULL)
        OR
        (idempotency_key IS NOT NULL AND octet_length(idempotency_hash) = 32)
    );

CREATE UNIQUE INDEX uq_pos_sales_store_idempotency
    ON pos_sales(store_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX ix_pos_sales_cash_session ON pos_sales(cash_session_id)
    WHERE cash_session_id IS NOT NULL;

ALTER TABLE pos_payments
    ADD COLUMN cash_received_amount numeric(18,2),
    ADD COLUMN change_amount numeric(18,2) NOT NULL DEFAULT 0,
    ADD CONSTRAINT ck_pos_payments_cash_received
        CHECK (cash_received_amount IS NULL OR cash_received_amount >= amount),
    ADD CONSTRAINT ck_pos_payments_change CHECK (change_amount >= 0),
    ADD CONSTRAINT ck_pos_payments_cash_change_consistency CHECK (
        (cash_received_amount IS NULL AND change_amount = 0)
        OR
        (cash_received_amount IS NOT NULL
          AND change_amount = cash_received_amount - amount)
    );

COMMENT ON COLUMN pos_sales.cash_session_id IS
    'Cash session that owns this sale; required by Store API for MVP transactions.';
COMMENT ON COLUMN pos_sales.idempotency_key IS
    'Client request key to prevent duplicate sale creation on retry.';
COMMENT ON COLUMN pos_sales.idempotency_hash IS
    'SHA-256 hash of canonical create-sale request; same key with different body is rejected.';
COMMENT ON COLUMN pos_payments.cash_received_amount IS
    'Cash tendered by customer; amount remains the applied payment amount.';
COMMENT ON COLUMN pos_payments.change_amount IS
    'Change returned to customer; cash_received_amount minus amount.';

COMMIT;
