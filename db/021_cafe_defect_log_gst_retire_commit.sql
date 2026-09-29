/* ============================================================================
   Bowerbird Verifier - migration 021 - COMMIT-ONLY
   Cafe invoices: add defect_log, retire gst_assessed from the review screens.

   DRAFT. Written without access to RULE-SQL (the kws115 connector was not
   attached), from the shape summarised in HANDOVER.md section 2.2. Check it
   against the rule body before running:
     SELECT body FROM normalisation.v_rules_current WHERE rule_id = 'RULE-SQL';

   COMMIT-ONLY. Three writing steps, each its own transaction, each idempotent.
   No trailing ROLLBACK.

   Run:  psql kws115 -f db/021_cafe_defect_log_gst_retire_commit.sql

   WHAT IT DOES
     1  cafe.invoices gains defect_log text (nullable).
     2  staging.record_type cafe_invoice declares a defect_log field.
     3  staging.record_type cafe_line marks gst_assessed hidden and not
        editable. It is NOT removed from the registry: the ingester refuses a
        batch carrying a field the registry does not declare, and the weekly
        producer and 22 pending lines still carry it. It is still written to
        cafe.purchases.gst_assessed on promotion, because that column holds the
        only GST on many lines (Tom, 29 September). Hidden means hidden from
        the screens, not dropped from production.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 pre-flight' AS check;

DO $preflight$
DECLARE
    v_types integer;
BEGIN
    IF to_regclass('cafe.invoices') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: cafe.invoices does not exist';
    END IF;
    SELECT count(*) INTO v_types FROM staging.record_type
    WHERE record_type IN ('cafe_invoice', 'cafe_line');
    IF v_types <> 2 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: expected cafe_invoice and cafe_line in the registry, found %', v_types;
    END IF;
END
$preflight$;

SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull
FROM pg_catalog.pg_attribute a
WHERE a.attrelid = 'cafe.invoices'::regclass
  AND a.attname = 'defect_log' AND NOT a.attisdropped;

SELECT 'STEP 1 cafe.invoices.defect_log' AS check;

BEGIN;

ALTER TABLE cafe.invoices ADD COLUMN IF NOT EXISTS defect_log text;

COMMENT ON COLUMN cafe.invoices.defect_log IS
    'Free text: defects found on receipt (short delivery, damage, wrong item). Entered in the verifier app.';

COMMIT;

SELECT 'STEP 2 register defect_log on cafe_invoice' AS check;

BEGIN;

UPDATE staging.record_type
SET field_spec = jsonb_set(
        field_spec, '{fields}',
        (field_spec -> 'fields')
        || '[{"name":"defect_log","label":"Defect log","type":"longtext","editable":true,"required":false}]'::jsonb)
WHERE record_type = 'cafe_invoice'
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(field_spec -> 'fields') f
                  WHERE f ->> 'name' = 'defect_log');

SELECT count(*) AS step2_cafe_invoice_fields_with_defect_log
FROM staging.record_type
WHERE record_type = 'cafe_invoice'
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(field_spec -> 'fields') f
              WHERE f ->> 'name' = 'defect_log');

COMMIT;

SELECT 'STEP 3 hide gst_assessed on cafe_line' AS check;

BEGIN;

UPDATE staging.record_type
SET field_spec = jsonb_set(
        field_spec, '{fields}',
        (SELECT jsonb_agg(
                    CASE WHEN t.f ->> 'name' = 'gst_assessed'
                         THEN t.f || '{"hidden":true,"editable":false,"required":false}'::jsonb
                         ELSE t.f END
                    ORDER BY t.ord)
         FROM jsonb_array_elements(field_spec -> 'fields') WITH ORDINALITY AS t(f, ord)))
WHERE record_type = 'cafe_line'
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(field_spec -> 'fields') f
              WHERE f ->> 'name' = 'gst_assessed'
                AND coalesce((f ->> 'hidden')::boolean, false) IS NOT TRUE);

COMMIT;

SELECT 'STEP 4 assertions' AS check;

DO $verify$
DECLARE
    v_col     integer;
    v_defect  integer;
    v_hidden  integer;
    v_fields  integer;
BEGIN
    SELECT count(*) INTO v_col
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = 'cafe.invoices'::regclass
      AND a.attname = 'defect_log' AND NOT a.attisdropped;
    IF v_col <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe.invoices.defect_log is missing';
    END IF;

    SELECT count(*) INTO v_defect
    FROM staging.record_type rt, jsonb_array_elements(rt.field_spec -> 'fields') f
    WHERE rt.record_type = 'cafe_invoice' AND f ->> 'name' = 'defect_log';
    IF v_defect <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe_invoice declares defect_log % time(s), expected 1', v_defect;
    END IF;

    SELECT count(*) INTO v_hidden
    FROM staging.record_type rt, jsonb_array_elements(rt.field_spec -> 'fields') f
    WHERE rt.record_type = 'cafe_line' AND f ->> 'name' = 'gst_assessed'
      AND (f ->> 'hidden')::boolean IS TRUE;
    IF v_hidden <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe_line gst_assessed is not hidden';
    END IF;

    SELECT count(*) INTO v_fields
    FROM staging.record_type rt, jsonb_array_elements(rt.field_spec -> 'fields') f
    WHERE rt.record_type = 'cafe_line' AND f ->> 'name' = 'gst_assessed';
    IF v_fields <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: gst_assessed must stay declared exactly once on cafe_line, found %', v_fields;
    END IF;
END
$verify$;

SELECT 'migration 021 complete' AS result;
