/* ============================================================================
   Bowerbird Verifier - migration 009 - COMMIT-ONLY
   Least-privilege grants so verifier_app can promote into accounting.*

   COMMIT-ONLY. One step, idempotent - a GRANT already held is a no-op. No
   trailing ROLLBACK. There is no separate dry-run file: this script reads
   nothing and changes no row, and a dry run of a GRANT proves nothing that
   the assertion at the end does not prove better.

   Run:  psql kws115 -f 009_promotion_grants_commit.sql

   WHY THIS EXISTS, AND WHY IT SURFACED AS A CONFUSING ERROR
     Migrations 001-003 granted verifier_app the cafe tables only. Promotion
     into accounting.* was never granted, so the first real promotion attempt
     failed - but it failed with "destination accounting.invoices does not
     exist", which is wrong and sent the reader looking for a missing table.

     The cause is that information_schema is PRIVILEGE-FILTERED: it shows a
     role only the objects it has some privilege on. promote.py used it to
     discover the destination's columns, got an empty set, and concluded the
     table was absent. The table was there all along. promote.py now reads
     pg_catalog, which is not filtered, and checks has_table_privilege
     separately so a missing grant reports itself as a missing grant.

   SELECT AND INSERT ONLY. Promotion inserts rows and reads them back to
   check for duplicates. It never updates or deletes in accounting.*, so
   those privileges are deliberately withheld - if a future change needs
   them, that should be its own decision and its own script.
   ============================================================================ */

SELECT 'STEP 1 grant SELECT and INSERT on the seven promotion destinations' AS check;

BEGIN;

GRANT SELECT, INSERT ON accounting.invoices TO verifier_app;
GRANT SELECT, INSERT ON accounting.main_meter_bills TO verifier_app;
GRANT SELECT, INSERT ON accounting.individual_meter_bills TO verifier_app;
GRANT SELECT, INSERT ON accounting.main_meter_bill_charges TO verifier_app;
GRANT SELECT, INSERT ON accounting.individual_meter_bill_charges TO verifier_app;
GRANT SELECT, INSERT ON accounting.main_meter_bill_other_charges TO verifier_app;
GRANT SELECT, INSERT ON accounting.individual_meter_bill_other_charges TO verifier_app;

GRANT USAGE, SELECT ON SEQUENCE accounting.invoices_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.main_meter_bills_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.individual_meter_bills_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.main_meter_bill_charges_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.individual_meter_bill_charges_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.main_meter_bill_other_charges_id_seq TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE accounting.individual_meter_bill_other_charges_id_seq TO verifier_app;

COMMIT;

SELECT count(*) AS step1_accounting_tables_granted
FROM information_schema.role_table_grants
WHERE grantee = 'verifier_app' AND table_schema = 'accounting'
  AND privilege_type IN ('SELECT','INSERT');

SELECT 'STEP 2 final read-only verification' AS check;

DO $$
DECLARE
    v_tables text[] := ARRAY[
        'accounting.invoices',
        'accounting.main_meter_bills',
        'accounting.individual_meter_bills',
        'accounting.main_meter_bill_charges',
        'accounting.individual_meter_bill_charges',
        'accounting.main_meter_bill_other_charges',
        'accounting.individual_meter_bill_other_charges'];
    v_name text;
    v_missing text := '';
BEGIN
    FOREACH v_name IN ARRAY v_tables LOOP
        IF NOT has_table_privilege('verifier_app', v_name, 'SELECT') THEN
            v_missing := v_missing || ' SELECT:' || v_name;
        END IF;
        IF NOT has_table_privilege('verifier_app', v_name, 'INSERT') THEN
            v_missing := v_missing || ' INSERT:' || v_name;
        END IF;
    END LOOP;

    IF v_missing <> '' THEN
        RAISE EXCEPTION 'STEP 2 FAILED: verifier_app still lacks%', v_missing;
    END IF;

    IF NOT has_schema_privilege('verifier_app', 'accounting', 'USAGE') THEN
        RAISE EXCEPTION 'STEP 2 FAILED: verifier_app has no USAGE on schema accounting';
    END IF;

    RAISE NOTICE 'STEP 2 OK: verifier_app can SELECT and INSERT on all 7 destinations';
END
$$;

SELECT 'STEP 3 migration 009 complete' AS check;
