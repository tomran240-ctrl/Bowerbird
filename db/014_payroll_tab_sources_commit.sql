/* ============================================================================
   Bowerbird Verifier - migration 014 - COMMIT-ONLY
   Wire the payroll nav tab to its two parent record types.

   COMMIT-ONLY. One writing step, its own transaction, idempotent through
   ON CONFLICT. No trailing ROLLBACK.

   Run:  psql kws115 -f 014_payroll_tab_sources_commit.sql

   WHY THIS EXISTS - a defect in migration 013
     013 STEP 7b tried to insert these two rows with filter = NULL.
     staging.nav_tab_source.filter is NOT NULL DEFAULT '{}'::jsonb, and an
     explicit NULL overrides a default rather than falling back to it, so the
     insert raised, its transaction rolled back, and STEP 8 then correctly
     refused to certify a payroll tab with no sources.

     Everything else in 013 had already committed - the schema, five tables,
     the view, the grants and the four record types are all in place and
     correct. This script finishes the one step that did not.

     The pre-flight in 013 checked that every column it named existed, and
     that no NOT NULL column was left UNSUPPLIED. It did not check the
     nullability of columns it was supplying. That is the hole, and STEP 0
     below closes it for this script: it asserts that no value this insert
     provides is null against a NOT NULL column.

   FILTER VALUES
     Both rows take the default '{}' - no filter. The payroll tab shows every
     pay instruction and every Square hours run. Compare invoices_115kw, where
     kw_invoice is filtered to {"property_code": "115KW"} because one record
     type feeds two tabs. Nothing here needs splitting that way.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 refuse to start unless the insert can succeed' AS check;

DO $preflight$
DECLARE
    v_missing_types text;
    v_tabs          integer;
    v_notnull       text;
BEGIN
    IF to_regclass('staging.nav_tab_source') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: staging.nav_tab_source is not present. '
                        'Nothing was changed.';
    END IF;

    SELECT count(*) INTO v_tabs FROM staging.nav_tab WHERE tab_key = 'payroll';
    IF v_tabs <> 1 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: expected exactly one payroll nav tab, '
                        'found %. Nothing was changed.', v_tabs;
    END IF;

    /* Both record types must already be registered by 013, or this wires the
       tab to a queue that cannot exist. */
    SELECT string_agg(t.rt, ', ' ORDER BY t.rt) INTO v_missing_types
    FROM (VALUES ('payroll_instruction'), ('payroll_hours_run')) AS t(rt)
    WHERE NOT EXISTS (SELECT 1 FROM staging.record_type r
                      WHERE r.record_type = t.rt AND r.active);
    IF v_missing_types IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: record type(s) not registered and '
                        'active: %. Run 013 first. Nothing was changed.',
                        v_missing_types;
    END IF;

    /* The check 013 was missing. Every column this insert names must either
       accept null or be given a non-null value. This insert supplies
       tab_key, record_type and sort_order, and deliberately omits filter so
       its default applies - so filter must HAVE a default. */
    SELECT string_agg(a.attname, ', ' ORDER BY a.attname) INTO v_notnull
    FROM pg_attribute a
    JOIN pg_class c        ON c.oid = a.attrelid
    JOIN pg_namespace n    ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE n.nspname = 'staging'
      AND c.relname = 'nav_tab_source'
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.attnotnull
      AND d.adbin IS NULL
      AND a.attname NOT IN ('tab_key', 'record_type', 'sort_order');
    IF v_notnull IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: column(s) % are NOT NULL with no '
                        'default and this insert supplies no value for them. '
                        'Nothing was changed.', v_notnull;
    END IF;

    RAISE NOTICE 'STEP 0 OK: payroll tab present, both record types active, '
                 'filter has a default to fall back on';
END
$preflight$;

SELECT 'STEP 1 wire the payroll tab to its two parent types' AS check;

BEGIN;

INSERT INTO staging.nav_tab_source (tab_key, record_type, sort_order)
VALUES ('payroll', 'payroll_instruction', 10)
ON CONFLICT (tab_key, record_type) DO NOTHING;

INSERT INTO staging.nav_tab_source (tab_key, record_type, sort_order)
VALUES ('payroll', 'payroll_hours_run', 20)
ON CONFLICT (tab_key, record_type) DO NOTHING;

COMMIT;

SELECT tab_key, record_type, filter::text AS filter, sort_order
FROM staging.nav_tab_source WHERE tab_key = 'payroll' ORDER BY sort_order;

SELECT 'STEP 2 assertions, including the ones 013 could not reach' AS check;

DO $verify$
DECLARE
    v_sources  integer;
    v_nullf    integer;
    v_tables   integer;
    v_types    integer;
    v_grants   integer;
    v_orphan   text;
BEGIN
    SELECT count(*) INTO v_sources
    FROM staging.nav_tab_source WHERE tab_key = 'payroll';
    IF v_sources <> 2 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the payroll tab has % source(s), '
                        'expected 2', v_sources;
    END IF;

    SELECT count(*) INTO v_nullf
    FROM staging.nav_tab_source WHERE tab_key = 'payroll' AND filter IS NULL;
    IF v_nullf <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: % payroll source(s) have a null '
                        'filter', v_nullf;
    END IF;

    /* No tab anywhere may point at a record type that is not registered and
       active - the failure 013 was guarding against, checked across the whole
       table rather than just the rows written here. */
    SELECT string_agg(s.tab_key || ' -> ' || s.record_type, ', '
                      ORDER BY s.tab_key, s.record_type)
      INTO v_orphan
    FROM staging.nav_tab_source s
    WHERE NOT EXISTS (SELECT 1 FROM staging.record_type r
                      WHERE r.record_type = s.record_type AND r.active);
    IF v_orphan IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: tab source(s) point at an inactive or '
                        'unregistered record type: %', v_orphan;
    END IF;

    /* Re-run what 013 STEP 8 never got to, so 013 is certified end to end. */
    SELECT count(*) INTO v_tables
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'payroll' AND c.relkind = 'r'
      AND c.relname IN ('employee','pay_instruction','pay_instruction_line',
                        'hours_run','hours_line');
    IF v_tables <> 5 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 5 payroll tables, found %',
                        v_tables;
    END IF;

    IF to_regclass('payroll.v_pay_variance') IS NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: payroll.v_pay_variance is missing';
    END IF;

    SELECT count(*) INTO v_types
    FROM staging.record_type WHERE record_type LIKE 'payroll%' AND active;
    IF v_types <> 4 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 4 active payroll record '
                        'types, found %', v_types;
    END IF;

    SELECT count(*) INTO v_grants
    FROM information_schema.role_table_grants
    WHERE grantee = 'verifier_app' AND table_schema = 'payroll'
      AND privilege_type IN ('SELECT','INSERT');
    IF v_grants < 11 THEN
        RAISE EXCEPTION 'ASSERT FAILED: verifier_app holds only % SELECT/'
                        'INSERT privilege(s) in payroll, expected at least 11',
                        v_grants;
    END IF;

    RAISE NOTICE 'ASSERT OK: payroll tab has 2 sources, and 013 now stands '
                 'certified - 5 tables, 1 view, 4 record types, % privileges',
                 v_grants;
    RAISE NOTICE 'Next: seed payroll.employee. Nothing reconciles until the '
                 'bridge is seeded.';
END
$verify$;

SELECT 'STEP 3 migration 014 complete' AS check;
