/* ============================================================================
   Bowerbird Verifier - migration 010 - COMMIT-ONLY
   Cut the cafe queue over to the registry, and make the legacy cafe staging
   tables read-only.

   COMMIT-ONLY. Each step is its own transaction and each is idempotent - a
   REVOKE already in effect and an UPDATE that matches nothing are both
   no-ops. No trailing ROLLBACK. There is no dry-run file: this changes one
   configuration row and some grants, and the assertions prove the outcome
   better than a rollback would.

   Run:  psql kws115 -f 010_cafe_cutover_commit.sql

   ONLY RUN THIS AFTER THE DRAIN. staging.cafe_invoices must hold no rows in
   pending or verified: once write access is revoked, the legacy view cannot
   verify or import anything still sitting there. STEP 0 checks this and stops
   rather than stranding work in a table nobody can write to.

   APPLICATION CODE, which must already be in place when this runs:
     - the cafe tab is served by the registry grid, not the legacy list
     - LEGACY_AUTO_INGEST is off, so no page load tries to write to these
       tables. Left on, every refresh would raise a permission error.
     - Refresh calls /api/ingest-run; Import calls /api/promote.

   WHY REVOKE RATHER THAN DROP
     These tables hold the link between rows in cafe.invoices / cafe.purchases
     and the documents they came from - which PDF, who verified it, when it
     was imported. Dropping them destroys that. Revoking costs nothing, keeps
     the rows queryable, and is undone with one GRANT if the cutover has to be
     reversed.

     SELECT is deliberately retained.

   WHAT THESE TABLES ARE, STATED ACCURATELY
     They are a partial record, not an authoritative one. Of the 26 invoices
     they hold, 15 were imported through this app and are correctly marked.
     Eleven others were staged on 01 Sep 2026, imported into cafe.invoices on
     08 Sep 2026 by a different route entirely, and were never marked imported
     here - they sat in the queue as unfinished work for two weeks until
     migration 011 cleared them. Treat this archive as evidence of what the
     app itself did, and never as the definitive list of what reached
     production. That divergence is the reason the cafe queue is moving onto
     one path.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 refuse to run while work is still in the legacy queue' AS check;

DO $$
DECLARE
    v_open integer;
BEGIN
    SELECT count(*) INTO v_open
    FROM staging.cafe_invoices
    WHERE row_status IN ('pending', 'verified');

    IF v_open > 0 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: % cafe invoice(s) are still pending or '
                        'verified in the legacy queue. Finish importing them '
                        'before cutting over - after this script they cannot '
                        'be verified or imported. Nothing was changed.', v_open;
    END IF;

    RAISE NOTICE 'STEP 0 OK: the legacy cafe queue is drained';
END
$$;

SELECT 'STEP 1 count the cafe tab from staging.record' AS check;

BEGIN;

UPDATE staging.nav_tab
SET count_source = 'record'
WHERE tab_key = 'invoices_cafe'
  AND count_source IS DISTINCT FROM 'record';

COMMIT;

SELECT tab_key, count_source FROM staging.nav_tab WHERE tab_key = 'invoices_cafe';

SELECT 'STEP 2 revoke write access on the legacy tables, keep SELECT' AS check;

BEGIN;

REVOKE INSERT, UPDATE, DELETE ON staging.cafe_invoices FROM verifier_app;
REVOKE INSERT, UPDATE, DELETE ON staging.cafe_purchases FROM verifier_app;

REVOKE USAGE ON SEQUENCE staging.cafe_invoices_staging_id_seq FROM verifier_app;
REVOKE USAGE ON SEQUENCE staging.cafe_purchases_staging_id_seq FROM verifier_app;

COMMIT;

SELECT count(*) AS step2_remaining_write_privileges
FROM information_schema.role_table_grants
WHERE grantee = 'verifier_app' AND table_schema = 'staging'
  AND table_name IN ('cafe_invoices','cafe_purchases')
  AND privilege_type IN ('INSERT','UPDATE','DELETE');

SELECT 'STEP 3 final read-only verification' AS check;

DO $$
DECLARE
    v_writes integer;
    v_source text;
    v_invoices integer;
    v_lines integer;
BEGIN
    SELECT count(*) INTO v_writes
    FROM information_schema.role_table_grants
    WHERE grantee = 'verifier_app' AND table_schema = 'staging'
      AND table_name IN ('cafe_invoices','cafe_purchases')
      AND privilege_type IN ('INSERT','UPDATE','DELETE');
    IF v_writes <> 0 THEN
        RAISE EXCEPTION 'STEP 3 FAILED: % write privilege(s) remain', v_writes;
    END IF;

    IF NOT has_table_privilege('verifier_app', 'staging.cafe_invoices', 'SELECT') THEN
        RAISE EXCEPTION 'STEP 3 FAILED: SELECT on staging.cafe_invoices was lost';
    END IF;
    IF NOT has_table_privilege('verifier_app', 'staging.cafe_purchases', 'SELECT') THEN
        RAISE EXCEPTION 'STEP 3 FAILED: SELECT on staging.cafe_purchases was lost';
    END IF;

    SELECT count_source INTO v_source
    FROM staging.nav_tab WHERE tab_key = 'invoices_cafe';
    IF v_source IS DISTINCT FROM 'record' THEN
        RAISE EXCEPTION 'STEP 3 FAILED: the cafe tab still counts from %, so its '
                        'badge would disagree with the list it shows', v_source;
    END IF;

    /* No tab may still count from the legacy table - that was the last one. */
    IF EXISTS (SELECT 1 FROM staging.nav_tab WHERE count_source = 'legacy_cafe') THEN
        RAISE EXCEPTION 'STEP 3 FAILED: a tab still has count_source legacy_cafe';
    END IF;

    SELECT count(*) INTO v_invoices FROM staging.cafe_invoices;
    SELECT count(*) INTO v_lines FROM staging.cafe_purchases;
    RAISE NOTICE 'STEP 3 OK: cafe counts from staging.record, legacy tables '
                 'read-only, % invoice row(s) and % line row(s) preserved',
                 v_invoices, v_lines;
END
$$;

SELECT 'STEP 4 migration 010 complete' AS check;
