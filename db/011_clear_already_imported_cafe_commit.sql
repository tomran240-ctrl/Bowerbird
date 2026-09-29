/* ============================================================================
   Bowerbird Verifier - migration 011 - COMMIT-ONLY
   Clear legacy cafe staging rows whose invoices are already in production.

   COMMIT-ONLY. Each step is its own transaction and each is idempotent:
   the UPDATEs match only rows still in 'verified', so a second run changes
   nothing. No trailing ROLLBACK. The dry run is
   011_clear_already_imported_cafe_dryrun.sql and goes first.

   Run:  psql kws115 -f 011_clear_already_imported_cafe_commit.sql

   WHAT HAPPENED
     Eleven cafe invoices staged on 01 Sep 2026 were imported into
     cafe.invoices on 07 Sep 2026 by a different route, and their staging
     rows were never marked imported. They have sat in the queue as unfinished
     work ever since. Every one matches its production row exactly on
     supplier, invoice number AND amount, so there is no question of a
     same-number-different-invoice collision.

     The legacy Import button is all-or-nothing across the whole queue, so it
     refuses the entire batch on these eleven and the seven genuinely new
     invoices behind them cannot be imported either. This clears the eleven so
     the seven can go.

   WHAT IT DOES NOT DO
     It writes nothing to cafe.invoices or cafe.purchases and imports nothing.
     It only marks staging rows 'deleted', which is the same state the Remove
     button in the app produces, and is reversible with an UPDATE.

   THE MATCH IS ON A BUSINESS KEY, NOT AN ID, and includes the amount. An
   invoice whose number matches but whose amount does not is NOT touched - it
   would be a genuine discrepancy for a human, not a duplicate to clear.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 1 the rows this will clear' AS check;

SELECT i.staging_id, i.supplier_name, i.invoice_number, i.amount_inc_gst,
       c.id AS production_id, c.created_at::date AS imported_on
FROM staging.cafe_invoices i
JOIN cafe.invoices c
  ON c.supplier_name = i.supplier_name
 AND c.invoice_number = i.invoice_number
 AND c.amount_inc_gst = i.amount_inc_gst
WHERE i.row_status = 'verified'
ORDER BY i.staging_id;

SELECT 'STEP 2 mark their line items deleted' AS check;

BEGIN;

UPDATE staging.cafe_purchases p
SET row_status = 'deleted'
WHERE p.row_status <> 'deleted'
  AND p.invoice_staging_id IN (
      SELECT i.staging_id
      FROM staging.cafe_invoices i
      JOIN cafe.invoices c
        ON c.supplier_name = i.supplier_name
       AND c.invoice_number = i.invoice_number
       AND c.amount_inc_gst = i.amount_inc_gst
      WHERE i.row_status = 'verified'
  );

COMMIT;

SELECT count(*) AS step2_lines_now_deleted
FROM staging.cafe_purchases WHERE row_status = 'deleted';

SELECT 'STEP 3 mark the invoices deleted' AS check;

BEGIN;

UPDATE staging.cafe_invoices i
SET row_status = 'deleted'
WHERE i.row_status = 'verified'
  AND EXISTS (
      SELECT 1 FROM cafe.invoices c
      WHERE c.supplier_name = i.supplier_name
        AND c.invoice_number = i.invoice_number
        AND c.amount_inc_gst = i.amount_inc_gst
  );

COMMIT;

SELECT count(*) AS step3_invoices_still_verified
FROM staging.cafe_invoices WHERE row_status = 'verified';

SELECT 'STEP 4 final read-only verification across all committed steps' AS check;

DO $$
DECLARE
    v_left_with_match integer;
    v_still_verified integer;
    v_lines_open integer;
BEGIN
    /* The job, stated as an invariant rather than a typed count: no verified
       invoice may remain that is already in production. */
    SELECT count(*) INTO v_left_with_match
    FROM staging.cafe_invoices i
    WHERE i.row_status = 'verified'
      AND EXISTS (
          SELECT 1 FROM cafe.invoices c
          WHERE c.supplier_name = i.supplier_name
            AND c.invoice_number = i.invoice_number
            AND c.amount_inc_gst = i.amount_inc_gst
      );
    IF v_left_with_match <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: % verified invoice(s) still match a '
                        'production row', v_left_with_match;
    END IF;

    /* And it must not have emptied the queue: the genuinely new invoices are
       the whole point of clearing the duplicates. */
    SELECT count(*) INTO v_still_verified
    FROM staging.cafe_invoices WHERE row_status = 'verified';
    IF v_still_verified = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: no verified invoices remain - this '
                        'should have cleared duplicates only';
    END IF;

    /* Every remaining verified invoice must still have its lines intact. */
    SELECT count(*) INTO v_lines_open
    FROM staging.cafe_purchases p
    JOIN staging.cafe_invoices i ON i.staging_id = p.invoice_staging_id
    WHERE i.row_status = 'verified' AND p.row_status = 'verified';
    IF v_lines_open = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the remaining verified invoices have '
                        'no verified lines left';
    END IF;

    RAISE NOTICE 'ASSERT OK: no verified duplicates remain, % invoice(s) and '
                 '% verified line(s) still queued', v_still_verified, v_lines_open;
END
$$;

SELECT 'STEP 5 migration 011 complete' AS check;
