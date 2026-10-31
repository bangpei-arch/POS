-- Cloud master alignment for the Store API MVP.
-- Apply after database/cloud-migrations/001_mvp_cloud_schema.sql in cloud DB only.
BEGIN;

ALTER TABLE cloud.products
    ADD COLUMN base_uom_code varchar(20) NOT NULL DEFAULT 'pcs',
    ADD COLUMN version bigint NOT NULL DEFAULT 1,
    ADD CONSTRAINT ck_cloud_products_base_uom CHECK (length(trim(base_uom_code)) > 0),
    ADD CONSTRAINT ck_cloud_products_version CHECK (version > 0);

ALTER TABLE cloud.payment_methods
    ADD COLUMN method_type varchar(30) NOT NULL DEFAULT 'other',
    ADD COLUMN requires_reference boolean NOT NULL DEFAULT false,
    ADD COLUMN is_cash boolean NOT NULL DEFAULT false,
    ADD COLUMN version bigint NOT NULL DEFAULT 1,
    ADD CONSTRAINT ck_cloud_payment_methods_type CHECK (
        method_type IN ('cash','transfer','qris','debit','other')
    ),
    ADD CONSTRAINT ck_cloud_payment_methods_version CHECK (version > 0);

UPDATE cloud.payment_methods
SET method_type = CASE code
        WHEN 'CASH' THEN 'cash'
        WHEN 'TRANSFER' THEN 'transfer'
        WHEN 'QRIS' THEN 'qris'
        ELSE 'other'
    END,
    requires_reference = code IN ('TRANSFER','QRIS'),
    is_cash = code = 'CASH',
    version = 1,
    updated_at = now();

COMMIT;
