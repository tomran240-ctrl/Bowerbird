/* ============================================================================
   Bowerbird Verifier - migration 018 - COMMIT-ONLY
   Express the Square hours run in decimal hours, the way everything else is.

   COMMIT-ONLY. Four writing steps, each its own transaction, each idempotent -
   ADD COLUMN IF NOT EXISTS, DROP VIEW IF EXISTS, and registry updates guarded
   on their own outcome. No trailing ROLLBACK.

   Run:  psql kws115 -f 018_payroll_hours_in_hours_commit.sql

   WHY
     payroll.pay_instruction_line stores numeric(7,2) hours. payroll.hours_run
     and payroll.hours_line stored integer minutes. Two units for the same
     quantity in one schema, with v_pay_variance dividing one side by 60 to
     compare them, and a grid showing 1680 beside 28.00 on a payroll screen.
     Hours are the house convention - thirty minutes is 0.5 - and that is what
     a reader should be handed.

   WHY MINUTES ARE NOT SIMPLY REPLACED
     The run identity clocked = rostered + adj_a + adj_b is exact in integer
     minutes and is NOT exact in hours rounded to two places. One of the
     sixteen records already staged proves it:

         minutes   3615 + (-161) + 7 = 3461          exact
         hours    60.25 + (-2.68) + 0.12 = 57.69     but 3461 min = 57.68

     Storing hours as the truth would make that run fail its own CHECK. So
     minutes remain the stored quantity and keep the constraint, and hours
     become generated columns derived from them. One source, no drift, and
     nothing divides by 60 by hand ever again.

   AND WHY THE PRODUCER MAY NOW EMIT HOURS
     Going the other way is exact. h = round(m/60, 2) is within 0.005 h of
     m/60, so h * 60 is within 0.3 of m, and 0.3 < 0.5 - round(h * 60) can
     only ever land on m. Checked against all sixteen staged records: zero
     round-trip failures. The producer therefore emits hours, the promoter
     reconstructs minutes with round(hours * 60), and the CHECK on minutes
     verifies the reconstruction at write time rather than trusting it.

   AFTER THIS SCRIPT
     The sixteen payroll_hours_* records already in staging carry minute
     payloads that no longer match the registry. Remove and re-stage them:

         python3 staging_remove_batch.py --list
         python3 staging_remove_batch.py --batch <the two hours batches>
         python3 shim_payroll_hours.py
         python3 staging_ingest.py

     record_uid is derived from the natural key, which holds no figures, so
     the re-staged records carry the same uids. Nothing is duplicated.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 pre-flight' AS check;

DO $preflight$
DECLARE
    v_imported integer;
BEGIN
    IF to_regclass('payroll.hours_run') IS NULL
       OR to_regclass('payroll.hours_line') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: the payroll tables are not present. '
                        'Nothing was changed.';
    END IF;

    /* Generated columns are derived, so adding them cannot disturb a row.
       But a record already promoted would mean the registry change below
       leaves staged and production rows describing the same figures in
       different units, so say so loudly. */
    SELECT count(*) INTO v_imported
    FROM staging.record
    WHERE record_type IN ('payroll_hours_run', 'payroll_hours_line')
      AND row_status = 'imported';
    IF v_imported > 0 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: % Square hours record(s) are already '
                        'imported. Changing the registry units now would '
                        'leave staged and production rows disagreeing. '
                        'Resolve those first. Nothing was changed.', v_imported;
    END IF;

    RAISE NOTICE 'STEP 0 OK: nothing promoted yet, safe to change units';
END
$preflight$;

SELECT 'STEP 1 add generated hour columns' AS check;

BEGIN;

ALTER TABLE payroll.hours_run
    ADD COLUMN IF NOT EXISTS rostered_hours numeric(8,2)
        GENERATED ALWAYS AS (round(rostered_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS adj_a_hours numeric(8,2)
        GENERATED ALWAYS AS (round(adj_a_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS adj_b_hours numeric(8,2)
        GENERATED ALWAYS AS (round(adj_b_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS clocked_hours numeric(8,2)
        GENERATED ALWAYS AS (round(clocked_minutes / 60.0, 2)) STORED;

ALTER TABLE payroll.hours_line
    ADD COLUMN IF NOT EXISTS rostered_hours numeric(8,2)
        GENERATED ALWAYS AS (round(rostered_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS adj_a_hours numeric(8,2)
        GENERATED ALWAYS AS (round(adj_a_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS adj_b_hours numeric(8,2)
        GENERATED ALWAYS AS (round(adj_b_minutes / 60.0, 2)) STORED,
    ADD COLUMN IF NOT EXISTS clocked_hours numeric(8,2)
        GENERATED ALWAYS AS (round(clocked_minutes / 60.0, 2)) STORED;

COMMENT ON COLUMN payroll.hours_run.rostered_hours IS
    'Derived from rostered_minutes. Minutes are the stored quantity because '
    'clocked = rostered + adj_a + adj_b is exact in minutes and is not exact '
    'in hours rounded to two places. Read hours; trust minutes.';

COMMENT ON COLUMN payroll.hours_line.rostered_hours IS
    'Derived from rostered_minutes. See the note on payroll.hours_run.';

COMMIT;

SELECT count(*) AS step1_generated_hour_columns
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'payroll' AND c.relname IN ('hours_run', 'hours_line')
  AND a.attname LIKE '%\_hours' AND a.attgenerated = 's'
  AND a.attnum > 0 AND NOT a.attisdropped;

SELECT 'STEP 2 the registry now declares hours, not minutes' AS check;

BEGIN;

UPDATE staging.record_type
SET field_spec = jsonb_set(field_spec, '{fields}', '[
    {"name":"pay_week_end","type":"date","label":"Week ending",
     "editable":false,"required":true},
    {"name":"run_date","type":"date","label":"Run date",
     "editable":false,"required":true},
    {"name":"rostered_hours","type":"number","label":"Rostered",
     "editable":false,"required":true},
    {"name":"adj_a_hours","type":"number","label":"ADJ A",
     "editable":false,"required":true},
    {"name":"adj_b_hours","type":"number","label":"ADJ B",
     "editable":false,"required":true},
    {"name":"clocked_hours","type":"number","label":"Clocked",
     "editable":false,"required":true},
    {"name":"settled_from","type":"date","label":"Settled from",
     "editable":false,"required":false},
    {"name":"settled_to","type":"date","label":"Settled to",
     "editable":false,"required":false},
    {"name":"carryback_from","type":"date","label":"Carry-back from",
     "editable":false,"required":false},
    {"name":"carryback_to","type":"date","label":"Carry-back to",
     "editable":false,"required":false},
    {"name":"deferred_from","type":"date","label":"Deferred from",
     "editable":false,"required":false},
    {"name":"deferred_to","type":"date","label":"Deferred to",
     "editable":false,"required":false},
    {"name":"exceptions_action","type":"number","label":"Action",
     "editable":false,"required":false},
    {"name":"exceptions_review","type":"number","label":"Review",
     "editable":false,"required":false},
    {"name":"exceptions_note","type":"number","label":"Noted",
     "editable":false,"required":false},
    {"name":"generated","type":"text","label":"Generated",
     "editable":false,"required":false},
    {"name":"notes","type":"longtext","label":"Notes",
     "editable":true,"required":false}
]'::jsonb),
    validation = jsonb_set(validation, '{reconcile}',
        '{"sum":"rostered_hours","mode":"block","against":"rostered_hours",
          "children":"payroll_hours_line"}'::jsonb)
WHERE record_type = 'payroll_hours_run';

UPDATE staging.record_type
SET field_spec = jsonb_set(field_spec, '{fields}', '[
    {"name":"staff_name","type":"text","label":"Name",
     "editable":false,"required":true},
    {"name":"role","type":"text","label":"Role",
     "editable":false,"required":false},
    {"name":"rostered_hours","type":"number","label":"Rostered",
     "editable":false,"required":true},
    {"name":"adj_a_hours","type":"number","label":"ADJ A",
     "editable":false,"required":true},
    {"name":"adj_b_hours","type":"number","label":"ADJ B",
     "editable":false,"required":true},
    {"name":"clocked_hours","type":"number","label":"Clocked",
     "editable":false,"required":true},
    {"name":"notes","type":"longtext","label":"Notes",
     "editable":true,"required":false}
]'::jsonb)
WHERE record_type = 'payroll_hours_line';

COMMIT;

SELECT record_type,
       jsonb_path_query_array(field_spec, '$.fields[*].name') AS declared_fields
FROM staging.record_type
WHERE record_type IN ('payroll_hours_run', 'payroll_hours_line')
ORDER BY record_type;

SELECT 'STEP 3 rebuild the variance view on the generated columns' AS check;

BEGIN;

DROP VIEW IF EXISTS payroll.v_pay_variance;

CREATE VIEW payroll.v_pay_variance AS
WITH tol AS (
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
           hl.rostered_hours, hl.adj_a_hours, hl.adj_b_hours
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
    hrs.rostered_hours,
    round(ins.total_hours - hrs.rostered_hours, 2)  AS variance_hours,
    hrs.adj_a_hours,
    hrs.adj_b_hours,
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
        WHEN abs(ins.total_hours - hrs.rostered_hours) <= t.tolerance_hours
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
    'week, in both directions. Both sides are decimal hours now - nothing '
    'divides by 60 here. Joined through '
    'payroll.employee.square_team_member_id.';

GRANT SELECT ON payroll.v_pay_variance TO verifier_app;

COMMIT;

SELECT count(*) AS step3_variance_rows FROM payroll.v_pay_variance;

SELECT 'STEP 4 assertions' AS check;

DO $verify$
DECLARE
    v_gen   integer;
    v_defs  text;
    v_minf  text;
BEGIN
    SELECT count(*) INTO v_gen
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'payroll' AND c.relname IN ('hours_run', 'hours_line')
      AND a.attname LIKE '%\_hours' AND a.attgenerated = 's'
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_gen <> 8 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 8 generated hour columns, '
                        'found %', v_gen;
    END IF;

    /* The minute columns and their constraint must survive - they are the
       exact quantity and the reason this was not a straight replacement. */
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                   JOIN pg_class t ON t.oid = c.conrelid
                   JOIN pg_namespace n ON n.oid = t.relnamespace
                   WHERE n.nspname='payroll' AND t.relname='hours_run'
                     AND c.conname='hours_run_clocked_identity') THEN
        RAISE EXCEPTION 'ASSERT FAILED: the minute identity constraint on '
                        'hours_run was lost';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                   JOIN pg_class t ON t.oid = c.conrelid
                   JOIN pg_namespace n ON n.oid = t.relnamespace
                   WHERE n.nspname='payroll' AND t.relname='hours_line'
                     AND c.conname='hours_line_clocked_identity') THEN
        RAISE EXCEPTION 'ASSERT FAILED: the minute identity constraint on '
                        'hours_line was lost';
    END IF;

    /* No payroll record type may still declare a field in minutes, or the
       grid goes back to showing 1680 beside 28.00. */
    SELECT string_agg(rt.record_type || '.' || f.name, ', ') INTO v_minf
    FROM staging.record_type rt,
         jsonb_to_recordset(rt.field_spec -> 'fields') AS f(name text)
    WHERE rt.record_type LIKE 'payroll%' AND f.name LIKE '%\_minutes';
    IF v_minf IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: field(s) still declared in minutes: %',
                        v_minf;
    END IF;

    v_defs := pg_get_viewdef('payroll.v_pay_variance', true);
    IF position('60.0' in v_defs) > 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the view still divides by 60 '
                        'somewhere - it should be reading the generated '
                        'hour columns';
    END IF;
    IF position('square_team_member_id' in v_defs) = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the view lost the Square id bridge';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
                   WHERE grantee='verifier_app' AND table_schema='payroll'
                     AND table_name='v_pay_variance'
                     AND privilege_type='SELECT') THEN
        RAISE EXCEPTION 'ASSERT FAILED: verifier_app cannot read the rebuilt '
                        'view';
    END IF;

    RAISE NOTICE 'ASSERT OK: 8 generated hour columns, minute constraints '
                 'intact, no field declared in minutes, view reads hours';
    RAISE NOTICE 'Now re-stage the Square hours: remove the two hours '
                 'batches, re-run shim_payroll_hours.py, ingest.';
END
$verify$;

SELECT 'STEP 5 migration 018 complete' AS check;
