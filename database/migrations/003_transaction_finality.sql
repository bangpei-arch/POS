-- POS transaction immutability and refund settlement guards
-- Migration: 003_transaction_finality.sql
-- Requires: 001_initial_schema.sql and 002_integrity_guards.sql
-- Paid sales/refunds are immutable. Refund header, lines and optional payout
-- breakdown must reconcile before a refund can become paid.

BEGIN;
SET search_path TO pos, public;

-- A paid sale must contain at least one line before it can be finalized.
CREATE OR REPLACE FUNCTION pos_guard_sale_paid_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_confirmed_total numeric(18,2);
  v_line_count bigint;
BEGIN
  IF NEW.status = 'paid' THEN
    SELECT COALESCE(sum(amount), 0)
      INTO v_confirmed_total
    FROM pos_payments
    WHERE sale_id = NEW.id AND status = 'confirmed';

    IF v_confirmed_total <> NEW.grand_total THEN
      RAISE EXCEPTION
        'Sale % cannot become paid: confirmed payments % do not equal grand_total %',
        NEW.id, v_confirmed_total, NEW.grand_total
        USING ERRCODE = '23514';
    END IF;

    SELECT count(*) INTO v_line_count
    FROM pos_sale_lines
    WHERE sale_id = NEW.id;

    IF v_line_count = 0 THEN
      RAISE EXCEPTION 'Sale % cannot become paid without sale lines', NEW.id
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Generic guard for sale header and its financial detail tables.
CREATE OR REPLACE FUNCTION pos_reject_paid_sale_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_sale_id uuid;
  v_status varchar(20);
BEGIN
  IF TG_TABLE_NAME = 'pos_sales' THEN
    IF TG_OP = 'INSERT' THEN
      RETURN NEW;
    END IF;
    IF OLD.status = 'paid' THEN
      RAISE EXCEPTION 'Paid sale % is immutable; use refund/reversal workflow', OLD.id
        USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_sale_id := (to_jsonb(OLD)->>'sale_id')::uuid;
  ELSE
    v_sale_id := (to_jsonb(NEW)->>'sale_id')::uuid;
  END IF;

  SELECT status INTO v_status FROM pos_sales WHERE id = v_sale_id;
  IF v_status = 'paid' THEN
    RAISE EXCEPTION 'Financial details of paid sale % are immutable', v_sale_id
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_paid_sale_immutable ON pos_sales;
CREATE TRIGGER trg_paid_sale_immutable
BEFORE UPDATE OR DELETE ON pos_sales
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_sale_mutation();

DROP TRIGGER IF EXISTS trg_paid_sale_lines_immutable ON pos_sale_lines;
CREATE TRIGGER trg_paid_sale_lines_immutable
BEFORE INSERT OR UPDATE OR DELETE ON pos_sale_lines
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_sale_mutation();

DROP TRIGGER IF EXISTS trg_paid_sale_discounts_immutable ON pos_sale_discounts;
CREATE TRIGGER trg_paid_sale_discounts_immutable
BEFORE INSERT OR UPDATE OR DELETE ON pos_sale_discounts
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_sale_mutation();

DROP TRIGGER IF EXISTS trg_paid_sale_payments_immutable ON pos_payments;
CREATE TRIGGER trg_paid_sale_payments_immutable
BEFORE INSERT OR UPDATE OR DELETE ON pos_payments
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_sale_mutation();

-- A refund may become paid only when its line detail equals its header amount.
-- If payout breakdown rows are used, confirmed payout rows must also reconcile.
CREATE OR REPLACE FUNCTION pos_guard_refund_settlement()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_line_count bigint;
  v_line_total numeric(18,2);
  v_payment_count bigint;
  v_payment_total numeric(18,2);
BEGIN
  IF NEW.status <> 'paid' THEN
    RETURN NEW;
  END IF;

  SELECT count(*), COALESCE(sum(refund_amount), 0)
    INTO v_line_count, v_line_total
  FROM pos_refund_lines
  WHERE refund_id = NEW.id;

  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'Refund % cannot become paid without refund lines', NEW.id
      USING ERRCODE = '23514';
  END IF;

  IF v_line_total <> NEW.total_amount THEN
    RAISE EXCEPTION
      'Refund % line total % does not equal header total %',
      NEW.id, v_line_total, NEW.total_amount
      USING ERRCODE = '23514';
  END IF;

  SELECT count(*), COALESCE(sum(amount) FILTER (WHERE status = 'confirmed'), 0)
    INTO v_payment_count, v_payment_total
  FROM pos_refund_payments
  WHERE refund_id = NEW.id;

  -- Payout breakdown is optional because refund_method_id on the header
  -- represents the single-method payout path. If breakdown rows exist,
  -- confirmed payout amount must equal the refund total.
  IF v_payment_count > 0 AND v_payment_total <> NEW.total_amount THEN
    RAISE EXCEPTION
      'Refund % confirmed payout total % does not equal header total %',
      NEW.id, v_payment_total, NEW.total_amount
      USING ERRCODE = '23514';
  END IF;

  IF NEW.completed_at IS NULL THEN
    RAISE EXCEPTION 'Paid refund % must have completed_at', NEW.id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_refund_settlement ON pos_refunds;
CREATE TRIGGER trg_guard_refund_settlement
BEFORE INSERT OR UPDATE OF status, total_amount ON pos_refunds
FOR EACH ROW EXECUTE FUNCTION pos_guard_refund_settlement();

-- Generic guard for a paid refund header.
CREATE OR REPLACE FUNCTION pos_reject_paid_refund_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_refund_id uuid;
  v_status varchar(20);
BEGIN
  IF TG_TABLE_NAME = 'pos_refunds' THEN
    IF TG_OP = 'INSERT' THEN
      RETURN NEW;
    END IF;
    IF OLD.status = 'paid' THEN
      RAISE EXCEPTION 'Paid refund % is immutable; use a recorded reversal', OLD.id
        USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_refund_id := (to_jsonb(OLD)->>'refund_id')::uuid;
  ELSE
    v_refund_id := (to_jsonb(NEW)->>'refund_id')::uuid;
  END IF;

  SELECT status INTO v_status FROM pos_refunds WHERE id = v_refund_id;
  IF v_status = 'paid' THEN
    RAISE EXCEPTION 'Details of paid refund % are immutable', v_refund_id
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_paid_refund_immutable ON pos_refunds;
CREATE TRIGGER trg_paid_refund_immutable
BEFORE UPDATE OR DELETE ON pos_refunds
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_refund_mutation();

DROP TRIGGER IF EXISTS trg_paid_refund_lines_immutable ON pos_refund_lines;
CREATE TRIGGER trg_paid_refund_lines_immutable
BEFORE INSERT OR UPDATE OR DELETE ON pos_refund_lines
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_refund_mutation();

DROP TRIGGER IF EXISTS trg_paid_refund_payments_immutable ON pos_refund_payments;
CREATE TRIGGER trg_paid_refund_payments_immutable
BEFORE INSERT OR UPDATE OR DELETE ON pos_refund_payments
FOR EACH ROW EXECUTE FUNCTION pos_reject_paid_refund_mutation();

-- Refund payout statuses are explicit; no arbitrary values.
ALTER TABLE pos_refund_payments
  ADD CONSTRAINT ck_refund_payment_status
  CHECK (status IN ('pending','confirmed','failed')) NOT VALID;
ALTER TABLE pos_refund_payments
  VALIDATE CONSTRAINT ck_refund_payment_status;

-- Query-supporting indexes identified in the schema audit.
CREATE INDEX IF NOT EXISTS ix_sale_lines_sale ON pos_sale_lines(sale_id);
CREATE INDEX IF NOT EXISTS ix_sale_status_events_sale_time
  ON pos_sale_status_events(sale_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_payment_events_payment_time
  ON pos_payment_events(payment_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_payment_evidence_payment_time
  ON pos_payment_evidence(payment_id, uploaded_at DESC);
CREATE INDEX IF NOT EXISTS ix_refund_lines_refund ON pos_refund_lines(refund_id);
CREATE INDEX IF NOT EXISTS ix_refund_payments_refund ON pos_refund_payments(refund_id);
CREATE INDEX IF NOT EXISTS ix_refund_events_refund_time
  ON pos_refund_events(refund_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_cash_session_events_session_time
  ON cash_session_events(session_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_sync_delivery_attempts_outbox_time
  ON sync_delivery_attempts(outbox_id, attempted_at DESC);
CREATE INDEX IF NOT EXISTS ix_sync_inbox_status_received
  ON sync_inbox(processing_status, received_at);

COMMENT ON FUNCTION pos_reject_paid_sale_mutation() IS
  'Rejects update/delete of paid sales and insert/update/delete of their financial details.';
COMMENT ON FUNCTION pos_guard_refund_settlement() IS
  'Requires refund line total to equal refund header and optional confirmed payout breakdown before PAID.';
COMMENT ON FUNCTION pos_reject_paid_refund_mutation() IS
  'Rejects update/delete of paid refunds and mutation of their detail/payout rows.';

COMMIT;
