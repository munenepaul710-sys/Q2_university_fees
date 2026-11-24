-- =====================================================================
-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL        PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL        PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students (student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL        PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments (payment_id),
    student_id INTEGER       NOT NULL REFERENCES students (student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE          PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202400001', 'Chanda Mwila',   5000.00),
    ('202400002', 'Mutale Banda',   3000.00),
    ('202400003', 'Natasha Phiri',  4000.00);   -- will have no payments

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;      -- full fee when no payments exist
END;
$$;

-- (c) PROCEDURE --------------------------------------------------------
-- The audit row is NOT inserted here; the trigger in (d) does that.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (received %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- Lock the student row so two simultaneous payments cannot overpay
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);   -- fee_due is not changed
END;
$$;

-- (d) TRIGGER ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) CONTINUED: SIX PAYMENTS THROUGH THE PROCEDURE --------------------
-- Student 1 owes 5000, pays 3000 (balance 2000)
-- Student 2 owes 3000, pays 3000 (fully settled)
-- Student 3 owes 4000, no payments
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;     -- one audit row per payment
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;

-- Rejected calls (each should raise an exception):
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);
-- CALL pr_receive_payment(1, -50, CURRENT_DATE);
-- CALL pr_receive_payment(1, 5000, CURRENT_DATE);   -- above balance of 2000
-- SELECT fn_fee_balance(99);                         -- unknown student

-- (e) VIEW -------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students excluded

SELECT * FROM v_fee_balances;

-- (f) INDEX ------------------------------------------------------------
-- Justification: queries test student_id with equality and paid_on with a
-- range. Equality column first, range column second, lets the index
-- locate one student's payments and read them in date order.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;     -- replaced, not added
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);     -- rerun replaces the row
SELECT * FROM daily_collections;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_collections_daily',
    '0 1 * * *',                                    -- every day at 01:00
    $job$CALL pr_refresh_collections(CURRENT_DATE - 1)$job$
);
