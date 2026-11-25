-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE employees (
    employee_id  SERIAL        PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL        PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month),
    CONSTRAINT ck_pay_month_start   CHECK (EXTRACT(DAY FROM pay_month) = 1)   -- first day of a month
);

CREATE TABLE salary_audit (
    audit_id    SERIAL        PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- ==== (b) Function fn_net_pay
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_deduc NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_deduc
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := v_basic + v_allow - v_deduc;           -- gross pay minus the fixed deduction
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ==== (c) Procedure pr_process_payroll (query FOR loop over active employees)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary + allowance AS gross
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);   -- raises on a bad calculation => whole CALL rolls back

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing row is left unchanged
    END LOOP;
END;
$$;

-- ==== (d) Trigger: AFTER UPDATE logging real basic_salary changes
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ==== (e) View v_payroll_report (inner join, no filter on active => history kept)
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- ==== (f) Index for a report filtered by pay_month across all employees
-- The existing UNIQUE (employee_id, pay_month) index leads with employee_id, so it cannot
-- serve a pay_month-only filter. This index leads with pay_month, so it is not a duplicate.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- ==== (g) Scheduled job: 02:00 on the 1st of every month, for the previous month
-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'process_payroll_monthly',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- ==== (a) Seed data: employees and two payroll months
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Mutale Chisha',  12000.00, 1500.00, 2000.00, TRUE),
    ('Mr. Kondwani Moyo',   9000.00, 1000.00, 1500.00, TRUE),
    ('Ms. Nkandu Sichone',  7500.00,  800.00, 1200.00, TRUE),
    ('Mr. Felix Tembo',     6000.00,  500.00,  900.00, TRUE);

CALL pr_process_payroll('2026-09-01');            -- September: all four are active
UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- Felix leaves
CALL pr_process_payroll('2026-10-01');            -- October: three active employees

SELECT * FROM employees ORDER BY employee_id;
SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- ==== (b) Function tests
SELECT employee_id, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY employee_id;
DO $$ BEGIN PERFORM fn_net_pay(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN
    UPDATE employees SET deduction = 99999 WHERE employee_id = 1;     -- deduction larger than gross
    PERFORM fn_net_pay(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;   -- block rolls the update back

-- ==== (c) Procedure tests
DO $$ BEGIN CALL pr_process_payroll('2026-11-15'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll(NULL);         EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- Existing rows stay unchanged even if the salary changed after processing:
UPDATE employees SET basic_salary = 13000 WHERE employee_id = 1;
CALL pr_process_payroll('2026-10-01');            -- rerun for an already processed month
SELECT employee_id, pay_month, gross_pay, net_pay FROM payroll WHERE employee_id = 1 ORDER BY pay_month;  -- still 13500 / 11500
SELECT COUNT(*) AS rows_for_october_still_3 FROM payroll WHERE pay_month = '2026-10-01';

-- An invalid calculation fails the WHOLE call: nothing is inserted for the new month
DO $$ BEGIN
    INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES ('Bad Data', 100, 0, 500);
    CALL pr_process_payroll('2026-11-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED (whole call failed): %', SQLERRM; END $$;
SELECT COUNT(*) AS rows_for_november_is_0 FROM payroll WHERE pay_month = '2026-11-01';
CALL pr_process_payroll('2026-11-01');            -- succeeds now (the bad employee was rolled back with the block)
SELECT COUNT(*) AS rows_for_november FROM payroll WHERE pay_month = '2026-11-01';

-- ==== (d) Trigger tests
SELECT * FROM salary_audit ORDER BY audit_id;                           -- the 12000 -> 13000 raise only
UPDATE employees SET allowance = 1600 WHERE employee_id = 2;            -- not a salary change
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2; -- same value
SELECT COUNT(*) AS audit_rows_still_1 FROM salary_audit;

-- ==== (e) View: Felix (now inactive) still appears for September
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- ==== (f) EXPLAIN
ANALYZE payroll;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- ==== (g) Inspect the job and its run history (pg_cron catalogue tables)
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'process_payroll_monthly';
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;
-- Useful administration commands:
--   SELECT cron.unschedule('process_payroll_monthly');   -- remove the job
--   UPDATE cron.job SET active = FALSE WHERE jobname = 'process_payroll_monthly';  -- pause it
