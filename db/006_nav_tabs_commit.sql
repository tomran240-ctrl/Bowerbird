/* ============================================================================
   Bowerbird Verifier - migration 006 - COMMIT-ONLY
   Navigation tabs, driven by the database rather than the template.

   COMMIT-ONLY. Each step is its own transaction and each step is
   individually idempotent, so a partial failure is resumed by running the
   file again. There is no trailing ROLLBACK and this file is not a dry run.
   The dry run is 006_nav_tabs_dryrun.sql and should be run first.

   Run:  psql kws115 -f 006_nav_tabs_commit.sql

   Additive only. It creates one table, adds one nullable column, and writes
   eight tab rows. No existing row is deleted and no record is moved.

   APPLICATION CODE. The nav bar and the /api/nav endpoint read these rows.
   They are prepared alongside this script and are harmless before it runs:
   the endpoint returns an empty tab list if staging.nav_tab is absent, and
   the page falls back to the single cafe view it has today.

   This migration writes no rule versions, so RULE-SQL pre-flight point 8 has
   no (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 1 create staging.nav_tab' AS check;

BEGIN;

CREATE TABLE IF NOT EXISTS staging.nav_tab (
    tab_key      text PRIMARY KEY,
    label        text NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('queue','page')),
    route        text,
    count_source text NOT NULL DEFAULT 'record'
        CHECK (count_source IN ('record','legacy_cafe','none')),
    sort_order   integer NOT NULL,
    active       boolean NOT NULL DEFAULT true,
    created_at   timestamp NOT NULL DEFAULT now(),
    CONSTRAINT nav_tab_page_needs_route CHECK (kind <> 'page' OR route IS NOT NULL)
);

COMMIT;

SELECT count(*) AS step1_nav_tab_rows FROM staging.nav_tab;

SELECT 'STEP 2 add record_type.nav_tab' AS check;

BEGIN;

ALTER TABLE staging.record_type
    ADD COLUMN IF NOT EXISTS nav_tab text REFERENCES staging.nav_tab(tab_key);

COMMIT;

SELECT count(*) AS step2_record_type_columns
FROM information_schema.columns
WHERE table_schema = 'staging' AND table_name = 'record_type' AND column_name = 'nav_tab';

SELECT 'STEP 3 grants for verifier_app' AS check;

BEGIN;

GRANT SELECT, INSERT, UPDATE, DELETE ON staging.nav_tab TO verifier_app;

COMMIT;

SELECT count(*) AS step3_nav_tab_privileges
FROM information_schema.role_table_grants
WHERE grantee = 'verifier_app' AND table_schema = 'staging' AND table_name = 'nav_tab';

SELECT 'STEP 4 register the eight tabs' AS check;

BEGIN;

INSERT INTO staging.nav_tab (tab_key, label, kind, route, count_source, sort_order) VALUES
    ('forms',          'Forms',          'queue', NULL,             'record',      10),
    ('invoices_115kw', 'Invoices 115KW', 'queue', NULL,             'record',      20),
    ('invoices_117kw', 'Invoices 117KW', 'queue', NULL,             'record',      30),
    ('invoices_cafe',  'Invoices Cafe',  'queue', NULL,             'legacy_cafe', 40),
    ('payroll',        'Payroll',        'queue', NULL,             'record',      50),
    ('reconciliation', 'Reconciliation', 'page',  'reconciliation', 'none',        60),
    ('batches',        'Batches',        'page',  'batches',        'none',        70),
    ('import_history', 'Import history', 'page',  'import-history', 'none',        80)
ON CONFLICT (tab_key) DO NOTHING;

COMMIT;

SELECT count(*) AS step4_tabs, count(*) FILTER (WHERE kind = 'queue') AS queues,
       count(*) FILTER (WHERE kind = 'page') AS pages
FROM staging.nav_tab;

SELECT 'STEP 5 point the cafe record type at its tab' AS check;

BEGIN;

UPDATE staging.record_type
SET nav_tab = 'invoices_cafe'
WHERE record_type = 'cafe_invoice'
  AND nav_tab IS DISTINCT FROM 'invoices_cafe';

COMMIT;

SELECT count(*) AS step5_types_with_a_tab
FROM staging.record_type WHERE nav_tab IS NOT NULL;

SELECT 'STEP 6 final read-only verification across all committed steps' AS check;

DO $$
DECLARE
    v_tabs integer;
    v_pages_without_route integer;
    v_cafe text;
    v_child text;
    v_grants integer;
BEGIN
    SELECT count(*) INTO v_tabs FROM staging.nav_tab;
    IF v_tabs <> 8 THEN
        RAISE EXCEPTION 'STEP 6 FAILED: expected 8 tabs, found %', v_tabs;
    END IF;

    SELECT count(*) INTO v_pages_without_route
    FROM staging.nav_tab WHERE kind = 'page' AND route IS NULL;
    IF v_pages_without_route <> 0 THEN
        RAISE EXCEPTION 'STEP 6 FAILED: % page tab(s) have no route', v_pages_without_route;
    END IF;

    SELECT nav_tab INTO v_cafe FROM staging.record_type WHERE record_type = 'cafe_invoice';
    IF v_cafe IS DISTINCT FROM 'invoices_cafe' THEN
        RAISE EXCEPTION 'STEP 6 FAILED: cafe_invoice nav_tab is %, expected invoices_cafe', v_cafe;
    END IF;

    SELECT nav_tab INTO v_child FROM staging.record_type WHERE record_type = 'cafe_line';
    IF v_child IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 6 FAILED: child type cafe_line has nav_tab %, expected none', v_child;
    END IF;

    SELECT count(*) INTO v_grants
    FROM information_schema.role_table_grants
    WHERE grantee = 'verifier_app' AND table_schema = 'staging'
      AND table_name = 'nav_tab' AND privilege_type = 'SELECT';
    IF v_grants <> 1 THEN
        RAISE EXCEPTION 'STEP 6 FAILED: verifier_app has no SELECT on staging.nav_tab';
    END IF;

    RAISE NOTICE 'STEP 6 OK: 8 tabs, every page routed, cafe mapped, child unmapped, grant in place';
END
$$;

SELECT 'STEP 7 migration 006 complete' AS check;
