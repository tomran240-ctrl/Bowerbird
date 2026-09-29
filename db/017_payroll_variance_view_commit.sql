/* ============================================================================
   Bowerbird Verifier - migration 017 - COMMIT-ONLY
   Rebuild payroll.v_pay_variance so it actually joins, and so it can see a
   person who worked but was not paid.

   COMMIT-ONLY. Two writing steps, each its own transaction. DROP VIEW IF
   EXISTS and DROP COLUMN IF EXISTS make both idempotent. No trailing
   ROLLBACK.

   Run:  psql kws115 -f 017_payroll_variance_view_commit.sql

   TWO FAULTS IN 013, BOTH FOUND BY BUILDING THE PRODUCERS AGAINST IT

   1. THE VIEW JOINED ON A COLUMN NOTHING FILLS.
      013 joined payroll.hours_line to payroll.employee on employee_code. But
      employee_code is not in the registry's field_spec for
      payroll_hours_line, because the Square side does not know it - Square
      identifies people by team member id. Promotion would have left that
      column null on every row, the join would have matched nothing, and the
      view would have reported NO HOURS RUN for every person in every week,
      permanently. The whole purpose of the feed, failing silently and
      looking like an empty queue.

      The bridge is payroll.employee.square_team_member_id. The view now
      traverses that, which is the link that actually exists.

      payroll.hours_line.employee_code is dropped. A foreign key column that
      nothing populates is not harmless: it invites exactly this join.

   2. THE VIEW COULD ONLY SEE ONE DIRECTION.
      Driven from the instruction, it could show a person paid for hours they
      did not work. It could not show the reverse - someone who appears in
      the Square hours run and on no pay instruction. That is the more
      serious error of the two, and during this build a parser fault produced
      exactly that appearance for one person over 21 weeks. It was a false
      alarm, but nothing in the database would have raised a true one.

      The view is now a FULL OUTER JOIN and reports both directions.

   STATUS VALUES
      OK                    within tolerance
      VARIANCE              paid hours differ from rostered beyond tolerance
      NOT IN HOURS RUN      paid, but absent from that week's Square run
      WORKED, NOT PAID      in the Square run, on no pay instruction
      UNKNOWN IN SQUARE     a Square id with no row in payroll.employee
      NO HOURS RUN          that pay week has no Square run at all

   Only WORKED, NOT PAID and VARIANCE are about money. NO HOURS RUN is
   ordinary for the 45 historical weeks that pre-date the Friday task.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 pre-flight' AS check;

DO $preflight$
DECLARE
    v_lines integer;
    v_col   integer;
BEGIN
    IF to_regclass('payroll.hours_line') IS NULL
       OR to_regclass('payroll.pay_instruction_line') IS NULL
       OR to_regclass('payroll.employee') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: the payroll tables are not present. '
                        'Run 013 first. Nothing was changed.';
    END IF;

    SELECT count(*) INTO v_lines FROM payroll.hours_line;
    IF v_lines > 0 THEN
        RAISE NOTICE 'STEP 0 NOTE: payroll.hours_line holds % row(s). '
                     'Dropping employee_code discards only nulls if the '
                     'column was never populated - check before running if '
                     'anything has filled it.', v_lines;
    END IF;

    SELECT count(*) INTO v_col
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'payroll' AND c.relname = 'hours_line'
      AND a.attname = 'employee_code' AND a.attnum > 0 AND NOT a.attisdropped;

    /* The bridge this view is about to depend on must exist and be populated,
       or the rebuild swaps one join that matches nothing for another. */
    IF NOT EXISTS (SELECT 1 FROM payroll.employee
                   WHERE square_team_member_id IS NOT NULL) THEN
        RAISE EXCEPTION 'STEP 0 FAILED: no row in payroll.employee carries a '
                        'square_team_member_id, so the new join would match '
                        'nothing either. Seed the register first (015). '
                        'Nothing was changed.';
    END IF;

    RAISE NOTICE 'STEP 0 OK: % hours line(s), employee_code present: %, '
                 'bridge populated', v_lines, (v_col = 1);
END
$preflight$;

SELECT 'STEP 1 drop the view and the column it wrongly relied on' AS check;

BEGIN;

DROP VIEW IF EXISTS payroll.v_pay_variance;

ALTER TABLE payroll.hours_line DROP COLUMN IF EXISTS employee_code;

COMMENT ON COLUMN payroll.hours_line.square_team_member_id IS
    'The only identifier the Square side has. It reaches a payroll employee '
    'through payroll.employee.square_team_member_id, which is the bridge. '
    'Do not add an employee_code column here: nothing on this side can fill '
    'it, and a null foreign key invites a join that matches nothing.';

COMMIT;

SELECT count(*) AS step1_employee_code_columns_left
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'payroll' AND c.relname = 'hours_line'
  AND a.attname = 'employee_code' AND a.attnum > 0 AND NOT a.attisdropped;

SELECT 'STEP 2 rebuild the view' AS check;

BEGIN;

CREATE VIEW payroll.v_pay_variance AS
WITH tol AS (
    /* One source of truth for the tolerance: the registry. Six minutes. */
    SELECT coalesce(
        (SELECT (validation -> 'cross_check' ->> 'tolerance_hours')::numeric
         FROM staging.record_type
         WHERE record_type = 'payroll_instruction'), 0.10) AS tolerance_hours
),
ins AS (
    SELECT i.period_end, l.employee_code, l.total_hours, l.document_note
    FROM payroll.pay_instruction i
    JOIN payroll.pay_instruction_line l ON l.instruction_id = i.id
    WHERE i.business_unit = 'Cafe'
),
hrs AS (
    SELECT r.pay_week_end AS period_end,
           hl.square_team_member_id,
           e.employee_code,
           hl.staff_name,
           hl.rostered_minutes, hl.adj_a_minutes, hl.adj_b_minutes
    FROM payroll.hours_run r
    JOIN payroll.hours_line hl ON hl.run_id = r.id
    LEFT JOIN payroll.employee e
           ON e.square_team_member_id = hl.square_team_member_id
)
SELECT
    coalesce(ins.period_end, hrs.period_end)        AS period_end,
    coalesce(ins.employee_code, hrs.employee_code)  AS employee_code,
    emp.surname,
    emp.first_name,
    hrs.square_team_member_id,
    hrs.staff_name                                  AS square_name,
    ins.total_hours                                 AS instruction_hours,
    round(hrs.rostered_minutes / 60.0, 2)           AS rostered_hours,
    round(ins.total_hours - hrs.rostered_minutes / 60.0, 2) AS variance_hours,
    round(hrs.adj_a_minutes / 60.0, 2)              AS adj_a_hours,
    round(hrs.adj_b_minutes / 60.0, 2)              AS adj_b_hours,
    ins.document_note,
    t.tolerance_hours,
    CASE
        WHEN ins.employee_code IS NULL AND hrs.employee_code IS NULL
            THEN 'UNKNOWN IN SQUARE'
        WHEN ins.employee_code IS NULL
            THEN 'WORKED, NOT PAID'
        WHEN hrs.period_end IS NULL
             AND NOT EXISTS (SELECT 1 FROM payroll.hours_run r2
                             WHERE r2.pay_week_end = ins.period_end)
            THEN 'NO HOURS RUN'
        WHEN hrs.period_end IS NULL
            THEN 'NOT IN HOURS RUN'
        WHEN abs(ins.total_hours - hrs.rostered_minutes / 60.0)
             <= t.tolerance_hours
            THEN 'OK'
        ELSE 'VARIANCE'
    END                                             AS status,
    (extract(isodow from coalesce(ins.period_end, hrs.period_end)) <> 7)
                                                    AS period_end_not_sunday
FROM ins
FULL OUTER JOIN hrs
    ON hrs.period_end = ins.period_end
   AND hrs.employee_code = ins.employee_code
LEFT JOIN payroll.employee emp
    ON emp.employee_code = coalesce(ins.employee_code, hrs.employee_code)
CROSS JOIN tol t
WHERE coalesce(emp.reconciled, true);

COMMENT ON VIEW payroll.v_pay_variance IS
    'Cafe pay instruction against Square ROSTERED hours, per person per pay '
    'week, in both directions. Joined through '
    'payroll.employee.square_team_member_id, which is the only link the two '
    'sources share. Clock variances are shown beside the figures and take no '
    'part in the comparison, because pay follows the roster.';

/* DROP VIEW discards its grants. Without this the app loses the one object
   the Payroll tab is going to read, and would report an empty queue rather
   than a permission error. */
GRANT SELECT ON payroll.v_pay_variance TO verifier_app;

COMMIT;

SELECT count(*) AS step2_variance_rows FROM payroll.v_pay_variance;

SELECT 'STEP 3 assertions' AS check;

DO $verify$
DECLARE
    v_col  integer;
    v_defs text;
BEGIN
    IF to_regclass('payroll.v_pay_variance') IS NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: the view was not created';
    END IF;

    SELECT count(*) INTO v_col
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'payroll' AND c.relname = 'hours_line'
      AND a.attname = 'employee_code' AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_col <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: hours_line.employee_code still exists';
    END IF;

    /* The view must reach the employee register through the Square id, not
       through a column on hours_line. Check the definition says so. */
    v_defs := pg_get_viewdef('payroll.v_pay_variance', true);
    IF position('square_team_member_id' in v_defs) = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the view does not mention '
                        'square_team_member_id, so it is not using the bridge';
    END IF;
    IF position('FULL JOIN' in upper(v_defs)) = 0
       AND position('FULL OUTER JOIN' in upper(v_defs)) = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the view is not a full outer join, so '
                        'it cannot report someone who worked and was not paid';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
                   WHERE grantee = 'verifier_app' AND table_schema = 'payroll'
                     AND table_name = 'v_pay_variance'
                     AND privilege_type = 'SELECT') THEN
        RAISE EXCEPTION 'ASSERT FAILED: verifier_app cannot read the rebuilt '
                        'view - the grant did not survive the drop';
    END IF;

    RAISE NOTICE 'ASSERT OK: view rebuilt on the Square id bridge, full outer '
                 'join, verifier_app can read it';
END
$verify$;

SELECT 'STEP 4 migration 017 complete' AS check;
