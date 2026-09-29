/* ============================================================================
   Bowerbird Verifier - migration 020 - COMMIT-ONLY
   Make the registry's enums mirror the destination CHECK constraints, as
   RULE-STG requires, instead of a hand-typed copy that has drifted.

   COMMIT-ONLY. One writing step, its own transaction, idempotent - it derives
   the values and writes them, so running it twice writes the same thing. No
   trailing ROLLBACK.

   Run:  psql kws115 -f 020_registry_enums_from_destination_commit.sql

   THE DRIFT
     RULE-STG: "ENUMS COME FROM THE DESTINATION. Where the target column
     carries a CHECK constraint, the registry mirrors it, and the producer
     emits only those values. Registering such a column as free text is how a
     typo passes review and fails at write."

     Two registry enums did not mirror their destination:

       cafe_line.surcharge_source
         registry     Invoice, Bank derived
         destination  Invoice, Bank derived, Invoice residual
         production   already holds 2 rows of 'Invoice residual'

       cafe_invoice.payment_status
         registry     Paid, Unpaid
         destination  Unpaid, Paid, Partially Paid, Disputed
         production   only Paid and Unpaid so far

     The first is live: RULE-CS v2 added 'Invoice residual' for an undisclosed
     surcharge, the column accepts it, production contains it, and the next
     Forest Food or EcoFlow invoice carrying it would have been refused at
     staging validation. The second has not been hit yet and would refuse the
     first partially paid or disputed cafe invoice that arrives.

   WHY THE VALUES ARE NOT TYPED HERE
     Typing them is what produced the drift. This script reads them out of
     pg_get_constraintdef and writes what it finds, so the registry matches
     the destination by construction rather than by someone remembering. If a
     CHECK gains a value tomorrow, re-running this script is the whole fix.

     The parse is asserted, not assumed: STEP 0 refuses to run unless each
     constraint is found and yields at least two values, and STEP 2 checks
     the stored enum against a freshly derived one.

   NOT DRIFT, DELIBERATELY LEFT ALONE
     kw_invoice.payment_status and kw_invoice.property_code have no CHECK on
     accounting.invoices at all. There the registry is the only guard and is
     deliberately narrower than the destination. Narrowing an unconstrained
     column is a choice; disagreeing with a constrained one is a fault.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 derive the values and refuse if the parse looks wrong' AS check;

CREATE OR REPLACE VIEW staging.v_enum_from_destination AS
WITH reg AS (
    SELECT rt.record_type, rt.target_schema, rt.target_table,
           e.key AS field, e.value AS registry_values
    FROM staging.record_type rt,
         jsonb_each(coalesce(rt.validation -> 'enums', '{}'::jsonb)) AS e
), def AS (
    SELECT r.record_type, r.field, r.registry_values,
           (SELECT pg_get_constraintdef(c.oid)
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.contype = 'c' AND n.nspname = r.target_schema
              AND t.relname = r.target_table
              AND pg_get_constraintdef(c.oid) LIKE '%' || r.field || ' = ANY%'
            LIMIT 1) AS constraint_def
    FROM reg r
)
SELECT d.record_type, d.field, d.registry_values, d.constraint_def,
       CASE WHEN d.constraint_def IS NULL THEN NULL ELSE (
           SELECT jsonb_agg(to_jsonb(m[1]) ORDER BY ord)
           FROM regexp_matches(d.constraint_def, '''([^'']+)''::text', 'g')
                WITH ORDINALITY AS t(m, ord)
       ) END AS destination_values
FROM def d;

COMMENT ON VIEW staging.v_enum_from_destination IS
    'Every registry enum beside the CHECK constraint on its destination '
    'column. destination_values is null where the destination has no CHECK, '
    'which is not drift - there the registry is the only guard. Any row where '
    'registry_values and destination_values differ is a batch waiting to be '
    'refused for a value the database would have accepted.';

GRANT SELECT ON staging.v_enum_from_destination TO verifier_app;

DO $preflight$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(record_type || '.' || field, ', ') INTO v_bad
    FROM staging.v_enum_from_destination
    WHERE field IN ('surcharge_source', 'payment_status')
      AND record_type IN ('cafe_line', 'cafe_invoice')
      AND (destination_values IS NULL OR jsonb_array_length(destination_values) < 2);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: could not read a sensible value list '
                        'out of the CHECK for %. The constraint text is not '
                        'the shape this parse expects. Nothing was changed.',
                        v_bad;
    END IF;
    RAISE NOTICE 'STEP 0 OK: both constraints parsed';
END
$preflight$;

SELECT record_type, field, registry_values::text AS registry,
       destination_values::text AS destination,
       (registry_values = destination_values) AS agrees
FROM staging.v_enum_from_destination ORDER BY record_type, field;

SELECT 'STEP 1 write the destination values into the registry' AS check;

BEGIN;

/* All drifting fields for a record type are merged in ONE patch. An
   UPDATE ... FROM that joined on record_type alone would fire once per row
   and fix only one field of a type that had two drifting, leaving the other
   silently behind. */

UPDATE staging.record_type rt
SET validation = jsonb_set(rt.validation, '{enums}',
                           (rt.validation -> 'enums') || v.patch)
FROM (
    SELECT record_type, jsonb_object_agg(field, destination_values) AS patch
    FROM staging.v_enum_from_destination
    WHERE destination_values IS NOT NULL
      AND registry_values IS DISTINCT FROM destination_values
    GROUP BY record_type
) v
WHERE v.record_type = rt.record_type;

COMMIT;

SELECT count(*) AS step1_enums_still_disagreeing
FROM staging.v_enum_from_destination
WHERE destination_values IS NOT NULL
  AND registry_values IS DISTINCT FROM destination_values;

SELECT 'STEP 2 assertions' AS check;

DO $verify$
DECLARE
    v_drift text;
    v_sur   jsonb;
    v_pay   jsonb;
BEGIN
    SELECT string_agg(record_type || '.' || field || ' registry=' ||
                      registry_values::text || ' destination=' ||
                      destination_values::text, '; ')
      INTO v_drift
    FROM staging.v_enum_from_destination
    WHERE destination_values IS NOT NULL
      AND registry_values IS DISTINCT FROM destination_values;
    IF v_drift IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: enum(s) still disagree with their '
                        'destination: %', v_drift;
    END IF;

    /* The two that prompted this, named rather than counted, so a future
       reader can see what was actually meant to change. */
    SELECT validation -> 'enums' -> 'surcharge_source' INTO v_sur
    FROM staging.record_type WHERE record_type = 'cafe_line';
    IF NOT (v_sur ? 'Invoice residual') THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe_line still will not accept '
                        'Invoice residual';
    END IF;

    SELECT validation -> 'enums' -> 'payment_status' INTO v_pay
    FROM staging.record_type WHERE record_type = 'cafe_invoice';
    IF NOT (v_pay ? 'Partially Paid' AND v_pay ? 'Disputed') THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe_invoice still will not accept '
                        'Partially Paid or Disputed';
    END IF;

    RAISE NOTICE 'ASSERT OK: every registry enum with a CHECK behind it now '
                 'mirrors it. surcharge_source = %, payment_status = %',
                 v_sur::text, v_pay::text;
    RAISE NOTICE 'staging.v_enum_from_destination will show this drift again '
                 'the moment a CHECK changes - query it, do not remember it.';
END
$verify$;

SELECT 'STEP 3 migration 020 complete' AS check;
