/* ============================================================================
   Bowerbird Verifier - migration 016 - COMMIT-ONLY
   Relax the pay instruction line sum from a constraint to a warning.

   COMMIT-ONLY. Two writing steps, each its own transaction, each idempotent -
   DROP CONSTRAINT IF EXISTS and a jsonb update guarded on its own outcome.
   No trailing ROLLBACK.

   Run:  psql kws115 -f 016_payroll_line_sum_warning_commit.sql

   WHY - a second defect of the same kind in migration 013
     013 gave payroll.pay_instruction_line this constraint:

         CHECK (total_hours = normal_hours + overtime_hours + adjustment_hours)

     A parse of all 535 data rows across the 47 payroll documents shows the
     documents do not always agree with it:

         2025-11-21  DEVI-F   normal 34.75  adj 0.00  total 32.25   (-2.50)
         2026-01-11  DEVI-F   normal  1.00  adj 0.00  total 37.00  (+36.00)
         2026-01-11  PIEL-M   normal 38.00  adj 0.00  total 36.00   (-2.00)

     These are the documents' own arithmetic, not a parsing fault - the same
     parse satisfies the identity on the other 532 rows. The constraint would
     reject three genuine historical instructions and stop the backfill.

     This is the same mistake as the Sunday constraint on period_end, made
     twice in one build: a CHECK written before the data it judges had been
     examined. The rule that follows is that a constraint may encode an
     invariant the SYSTEM guarantees, never one a human document is merely
     expected to honour. Document arithmetic belongs in the queue as a
     question, not in a constraint as a refusal.

     Worth noting where the three sit: all in 115connect and Farm, the two
     business units entered by hand with no second source to check them
     against. The unit that gets reconciled has none.

   WHAT REPLACES IT
     line_total_does_not_sum moves from validation.import_blocks to
     validation.warnings on payroll_instruction_line, so a row whose figures
     do not add up loads, surfaces in the queue, and waits for a person -
     which is what the verifier is for.

   SAFE TO RUN NOW. payroll.pay_instruction_line is empty, so dropping the
   constraint changes no existing row. STEP 0 checks that and says so.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 pre-flight' AS check;

DO $preflight$
DECLARE
    v_rows   integer;
    v_con    integer;
    v_type   integer;
BEGIN
    IF to_regclass('payroll.pay_instruction_line') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: payroll.pay_instruction_line does not '
                        'exist. Run 013 first. Nothing was changed.';
    END IF;

    SELECT count(*) INTO v_type FROM staging.record_type
    WHERE record_type = 'payroll_instruction_line';
    IF v_type <> 1 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: record type payroll_instruction_line '
                        'is not registered. Nothing was changed.';
    END IF;

    SELECT count(*) INTO v_rows FROM payroll.pay_instruction_line;
    IF v_rows > 0 THEN
        RAISE NOTICE 'STEP 0 NOTE: the table holds % row(s). Dropping the '
                     'constraint cannot invalidate them - it only stops '
                     'future rows being refused.', v_rows;
    END IF;

    SELECT count(*) INTO v_con
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'payroll' AND t.relname = 'pay_instruction_line'
      AND c.conname = 'pay_instruction_line_sums';
    IF v_con = 0 THEN
        RAISE NOTICE 'STEP 0 NOTE: the constraint is already absent; STEP 1 '
                     'will be a no-op.';
    END IF;

    RAISE NOTICE 'STEP 0 OK: % existing line(s), constraint present: %',
                 v_rows, (v_con = 1);
END
$preflight$;

SELECT 'STEP 1 drop the sum constraint' AS check;

BEGIN;

ALTER TABLE payroll.pay_instruction_line
    DROP CONSTRAINT IF EXISTS pay_instruction_line_sums;

COMMENT ON COLUMN payroll.pay_instruction_line.total_hours IS
    'The Total column as the document prints it, and the figure IPS pays. It '
    'is NOT constrained to equal normal + overtime + adjustment: three rows '
    'across the 47-document archive do not, and those are the documents own '
    'arithmetic. A row that does not add up is flagged in the queue as '
    'line_total_does_not_sum and waits for a person.';

COMMIT;

SELECT count(*) AS step1_sum_constraints_remaining
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'payroll' AND t.relname = 'pay_instruction_line'
  AND c.conname = 'pay_instruction_line_sums';

SELECT 'STEP 2 move the check from a block to a warning in the registry' AS check;

BEGIN;

UPDATE staging.record_type
SET validation = jsonb_set(
        jsonb_set(validation, '{import_blocks}',
                  (validation -> 'import_blocks') - 'line_total_does_not_sum'),
        '{warnings}',
        coalesce(validation -> 'warnings', '[]'::jsonb)
            || '["line_total_does_not_sum"]'::jsonb)
WHERE record_type = 'payroll_instruction_line'
  AND validation -> 'import_blocks' ? 'line_total_does_not_sum';

COMMIT;

SELECT record_type, jsonb_pretty(validation) AS validation
FROM staging.record_type WHERE record_type = 'payroll_instruction_line';

SELECT 'STEP 3 assertions' AS check;

DO $verify$
DECLARE
    v_con integer;
    v_val jsonb;
BEGIN
    SELECT count(*) INTO v_con
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'payroll' AND t.relname = 'pay_instruction_line'
      AND c.conname = 'pay_instruction_line_sums';
    IF v_con <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the sum constraint is still present';
    END IF;

    SELECT validation INTO v_val
    FROM staging.record_type WHERE record_type = 'payroll_instruction_line';

    IF v_val -> 'import_blocks' ? 'line_total_does_not_sum' THEN
        RAISE EXCEPTION 'ASSERT FAILED: line_total_does_not_sum is still an '
                        'import block, so the backfill would still be refused';
    END IF;
    IF NOT (v_val -> 'warnings' ? 'line_total_does_not_sum') THEN
        RAISE EXCEPTION 'ASSERT FAILED: line_total_does_not_sum is not a '
                        'warning, so a row that does not add up would load '
                        'silently - which is worse than either alternative';
    END IF;
    IF NOT (v_val -> 'import_blocks' ? 'unknown_employee_code') THEN
        RAISE EXCEPTION 'ASSERT FAILED: unknown_employee_code was lost from '
                        'import_blocks';
    END IF;

    /* The identities that the SYSTEM guarantees stay as constraints. Only the
       one a human document merely ought to honour was relaxed. */
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                   JOIN pg_class t ON t.oid = c.conrelid
                   JOIN pg_namespace n ON n.oid = t.relnamespace
                   WHERE n.nspname='payroll' AND t.relname='hours_run'
                     AND c.conname='hours_run_clocked_identity') THEN
        RAISE EXCEPTION 'ASSERT FAILED: hours_run_clocked_identity is missing '
                        '- that one is computed by us and must stay enforced';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                   JOIN pg_class t ON t.oid = c.conrelid
                   JOIN pg_namespace n ON n.oid = t.relnamespace
                   WHERE n.nspname='payroll' AND t.relname='hours_line'
                     AND c.conname='hours_line_clocked_identity') THEN
        RAISE EXCEPTION 'ASSERT FAILED: hours_line_clocked_identity is missing';
    END IF;

    RAISE NOTICE 'ASSERT OK: the document sum is a warning, the computed '
                 'identities remain constraints';
END
$verify$;

SELECT 'STEP 4 migration 016 complete' AS check;
