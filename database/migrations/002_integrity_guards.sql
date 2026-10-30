-- POS integrity guards
-- Migration: 002_integrity_guards.sql
-- Requires: 001_initial_schema.sql
-- Enforces paid-payment equality and cumulative refund limits at database level.
-- Refund-line checks serialize on the original sale-line row (SELECT ... FOR UPDATE).

BEGIN;
SET search_path TO pos, public;

CREATE OR REPLACE FUNCTION pos_guard_paid_sale_payment_total()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_sale_id uuid;
  v_ids uuid[];
  v_status varchar(20);
  v_grand_total numeric(18,2);
  v_confirmed_total numeric(18,2);
  v_exclude_payment_id uuid;
BEGIN
  v_exclude_payment_id := NULL;
  v_exclude_payment_id := NULL;
  IF TG_OP = 'INSERT' THEN
    v_ids := ARRAY[NEW.sale_id];
  ELSIF TG_OP = 'DELETE' THEN
    v_ids := ARRAY[OLD.sale_id];
    v_exclude_payment_id := OLD.id;
  ELSE
    v_ids := ARRAY[OLD.sale_id, NEW.sale_id];
    v_exclude_payment_id := OLD.id;
  END IF;

  -- Lock affected sale rows in deterministic order. This serializes payment
  -- mutations with the transition of the sale to paid.
  PERFORM id
  FROM pos_sales
  WHERE id = ANY(v_ids)
  ORDER BY id
  FOR UPDATE;

  FOREACH v_sale_id IN ARRAY v_ids LOOP
    SELECT status, grand_total
      INTO v_status, v_grand_total
    FROM pos_sales
    WHERE id = v_sale_id;

    IF NOT FOUND OR v_status <> 'paid' THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(sum(amount), 0)
      INTO v_confirmed_total
    FROM pos_payments
    WHERE sale_id = v_sale_id
      AND status = 'confirmed'
      AND id IS DISTINCT FROM v_exclude_payment_id;

    IF TG_OP <> 'DELETE'
       AND NEW.sale_id = v_sale_id
       AND NEW.status = 'confirmed' THEN
      v_confirmed_total := v_confirmed_total + NEW.amount;
    END IF;

    IF v_confirmed_total <> v_grand_total THEN
      RAISE EXCEPTION
        'Cannot change payment: paid sale % must have confirmed payments equal to grand_total (confirmed %, grand_total %)',
        v_sale_id, v_confirmed_total, v_grand_total
        USING ERRCODE = '23514';
    END IF;
  END LOOP;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_paid_sale_payment_total ON pos_payments;
CREATE TRIGGER trg_guard_paid_sale_payment_total
BEFORE INSERT OR UPDATE OR DELETE ON pos_payments
FOR EACH ROW EXECUTE FUNCTION pos_guard_paid_sale_payment_total();

CREATE OR REPLACE FUNCTION pos_guard_sale_paid_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_confirmed_total numeric(18,2);
  v_exclude_payment_id uuid;
BEGIN
  IF NEW.status = 'paid' THEN
    SELECT COALESCE(sum(amount), 0)
      INTO v_confirmed_total
    FROM pos_payments
    WHERE sale_id = NEW.id
      AND status = 'confirmed';

    IF v_confirmed_total <> NEW.grand_total THEN
      RAISE EXCEPTION
        'Sale % cannot become paid: confirmed payments % do not equal grand_total %',
        NEW.id, v_confirmed_total, NEW.grand_total
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_sale_paid_transition ON pos_sales;
CREATE TRIGGER trg_guard_sale_paid_transition
BEFORE INSERT OR UPDATE OF status, grand_total ON pos_sales
FOR EACH ROW EXECUTE FUNCTION pos_guard_sale_paid_transition();

CREATE OR REPLACE FUNCTION pos_guard_refund_line_limits()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_line_id uuid;
  v_sale_id uuid;
  v_refund_id uuid;
  v_refund_sale_id uuid;
  v_refund_status varchar(20);
  v_original_qty integer;
  v_original_amount numeric(18,2);
  v_refunded_qty bigint;
  v_refunded_amount numeric(18,2);
  v_exclude_refund_line_id uuid;
BEGIN
  v_exclude_refund_line_id := NULL;
  v_exclude_refund_line_id := NULL;
  IF TG_OP = 'DELETE' THEN
    v_line_id := OLD.original_sale_line_id;
    v_exclude_refund_line_id := OLD.id;
    v_exclude_refund_line_id := OLD.id;
    v_refund_id := OLD.refund_id;
  ELSE
    v_line_id := NEW.original_sale_line_id;
    v_refund_id := NEW.refund_id;
    IF TG_OP = 'UPDATE' THEN
      v_exclude_refund_line_id := OLD.id;
    END IF;
    IF TG_OP = 'UPDATE' THEN
      v_exclude_refund_line_id := OLD.id;
    END IF;
    IF TG_OP = 'UPDATE'
       AND (NEW.original_sale_line_id <> OLD.original_sale_line_id
            OR NEW.refund_id <> OLD.refund_id) THEN
      RAISE EXCEPTION
        'Refund line identity cannot be changed; delete/recreate only before refund is paid'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  -- This row is the serialization point shared by every refund against the
  -- same original sale line, including different refund headers.
  SELECT sale_id, quantity, line_total
    INTO v_sale_id, v_original_qty, v_original_amount
  FROM pos_sale_lines
  WHERE id = v_line_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Original sale line % does not exist', v_line_id
      USING ERRCODE = '23503';
  END IF;

  SELECT original_sale_id, status
    INTO v_refund_sale_id, v_refund_status
  FROM pos_refunds
  WHERE id = v_refund_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Refund % does not exist', v_refund_id
      USING ERRCODE = '23503';
  END IF;

  IF v_refund_sale_id <> v_sale_id THEN
    RAISE EXCEPTION
      'Refund % and original sale line % belong to different sales',
      v_refund_id, v_line_id
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF v_refund_status = 'paid' THEN
      RAISE EXCEPTION 'Paid refund lines cannot be deleted'
        USING ERRCODE = '23514';
    END IF;
    RETURN OLD;
  END IF;

  IF v_refund_status = 'paid' THEN
    SELECT
      COALESCE(sum(rl.quantity), 0),
      COALESCE(sum(rl.refund_amount), 0)
    INTO v_refunded_qty, v_refunded_amount
    FROM pos_refund_lines rl
    JOIN pos_refunds r ON r.id = rl.refund_id
    WHERE rl.original_sale_line_id = v_line_id
      AND r.status = 'paid'
      AND rl.id IS DISTINCT FROM v_exclude_refund_line_id;

    v_refunded_qty := v_refunded_qty + NEW.quantity;
    v_refunded_amount := v_refunded_amount + NEW.refund_amount;

    IF v_refunded_qty > v_original_qty THEN
      RAISE EXCEPTION
        'Refund quantity exceeds original sale line %: requested cumulative %, original %',
        v_line_id, v_refunded_qty, v_original_qty
        USING ERRCODE = '23514';
    END IF;

    IF v_refunded_amount > v_original_amount THEN
      RAISE EXCEPTION
        'Refund amount exceeds original sale line %: requested cumulative %, original %',
        v_line_id, v_refunded_amount, v_original_amount
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_refund_line_limits ON pos_refund_lines;
CREATE TRIGGER trg_guard_refund_line_limits
BEFORE INSERT OR UPDATE OR DELETE ON pos_refund_lines
FOR EACH ROW EXECUTE FUNCTION pos_guard_refund_line_limits();

CREATE OR REPLACE FUNCTION pos_guard_refund_paid_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pos, public
AS $$
DECLARE
  v_line record;
  v_original_sale_id uuid;
  v_original_qty integer;
  v_original_amount numeric(18,2);
  v_other_qty bigint;
  v_other_amount numeric(18,2);
  v_this_qty bigint;
  v_this_amount numeric(18,2);
BEGIN
  IF NEW.status <> 'paid'
     OR (TG_OP = 'UPDATE' AND OLD.status = 'paid') THEN
    RETURN NEW;
  END IF;

  -- Lock every original line touched by this refund in stable order. Other
  -- refund processes use the same locks in their refund-line trigger.
  FOR v_line IN
    SELECT DISTINCT original_sale_line_id
    FROM pos_refund_lines
    WHERE refund_id = NEW.id
    ORDER BY original_sale_line_id
  LOOP
    SELECT sale_id, quantity, line_total
      INTO v_original_sale_id, v_original_qty, v_original_amount
    FROM pos_sale_lines
    WHERE id = v_line.original_sale_line_id
    FOR UPDATE;

    IF v_original_sale_id <> NEW.original_sale_id THEN
      RAISE EXCEPTION
        'Refund % contains a line from a different original sale',
        NEW.id
        USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(sum(rl.quantity), 0),
           COALESCE(sum(rl.refund_amount), 0)
      INTO v_other_qty, v_other_amount
    FROM pos_refund_lines rl
    JOIN pos_refunds r ON r.id = rl.refund_id
    WHERE rl.original_sale_line_id = v_line.original_sale_line_id
      AND r.status = 'paid'
      AND r.id <> NEW.id;

    SELECT COALESCE(sum(quantity), 0),
           COALESCE(sum(refund_amount), 0)
      INTO v_this_qty, v_this_amount
    FROM pos_refund_lines
    WHERE refund_id = NEW.id
      AND original_sale_line_id = v_line.original_sale_line_id;

    IF v_other_qty + v_this_qty > v_original_qty THEN
      RAISE EXCEPTION
        'Refund % would exceed original quantity for sale line %: cumulative %, original %',
        NEW.id, v_line.original_sale_line_id,
        v_other_qty + v_this_qty, v_original_qty
        USING ERRCODE = '23514';
    END IF;

    IF v_other_amount + v_this_amount > v_original_amount THEN
      RAISE EXCEPTION
        'Refund % would exceed original amount for sale line %: cumulative %, original %',
        NEW.id, v_line.original_sale_line_id,
        v_other_amount + v_this_amount, v_original_amount
        USING ERRCODE = '23514';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_refund_paid_transition ON pos_refunds;
CREATE TRIGGER trg_guard_refund_paid_transition
BEFORE INSERT OR UPDATE OF status ON pos_refunds
FOR EACH ROW EXECUTE FUNCTION pos_guard_refund_paid_transition();

COMMENT ON FUNCTION pos_guard_sale_paid_transition() IS
  'A sale can be paid only when confirmed payment total exactly equals grand_total.';
COMMENT ON FUNCTION pos_guard_refund_line_limits() IS
  'Serializes refund line changes on the original sale line and prevents paid cumulative over-refunds.';
COMMENT ON FUNCTION pos_guard_refund_paid_transition() IS
  'Validates cumulative quantity and amount when a refund transitions to paid.';

COMMIT;
