/* ============================================================================
   Bowerbird Verifier - migration 007 - COMMIT-ONLY
   Tab sources with filters, and the seven building/electricity record types.

   COMMIT-ONLY. Each step is its own transaction and individually idempotent,
   so a partial failure is resumed by running the file again. No trailing
   ROLLBACK. The dry run is 007_tab_sources_dryrun.sql and goes first.

   APPLICATION CODE. /api/nav reads nav_tab_source instead of record_type.nav_tab.
   That edit is prepared with this script and applied the moment step 3 commits,
   because after the drop the old query would fail on a missing column.

   Run:  psql kws115 -f 007_tab_sources_commit.sql

   WHY THE TAB MAPPING MOVES OUT OF record_type
     Migration 006 put nav_tab on record_type, which allows a type on exactly
     one tab. kw_invoice has to appear on both Invoices 115KW and Invoices
     117KW, showing a different slice of the same type on each. That is a
     link, not an attribute, so it becomes staging.nav_tab_source carrying an
     optional filter. Changed now, one migration later, because nothing yet
     depends on the column.

   THIS SCRIPT COPIES BEFORE IT DROPS, AND BOTH HALVES ARE ONE OPERATION.
     Step 2 copies every existing record_type.nav_tab value into the new link
     table. Step 3 then drops that column. If step 2 is skipped or fails and
     step 3 runs, the cafe tab loses its record type and its queue silently
     renders empty - there is no error, because an unmapped tab is a legal
     state. Run the steps in order, and do not run step 3 alone.

   WHAT IT DOES NOT DO
     It writes nothing to accounting.* and stages no records. Registering a
     type only describes it. The 107 invoices and 206 meter bills already in
     production are not touched, read, or duplicated.

   SEVEN TYPES, ONE PER DESTINATION TABLE
     Electricity is six types rather than three because main and tenancy
     meters genuinely differ: main charges carry charge_group, dlf and mlf
     that tenancy charges do not, and tenancy bills require level and
     read_type that main bills do not have. One record type per target table
     keeps target_table meaningful and keeps the promote-mappers free of
     meter_type branching.

     Required flags follow each destination's NOT NULL columns. Checked
     against all 11 archived electricity workbooks first: on tenancy rows
     every such column is populated, and the columns always blank on main
     rows (level, read_type) are either absent from or nullable in
     main_meter_bills.

   payment_status is registered on kw_invoice but listed in
   dropped_on_promotion: accounting.invoices has no column for it. It stays
   visible during review and readable in staging afterwards.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 1 create staging.nav_tab_source' AS check;

BEGIN;

CREATE TABLE IF NOT EXISTS staging.nav_tab_source (
    tab_key     text NOT NULL REFERENCES staging.nav_tab(tab_key) ON DELETE CASCADE,
    record_type text NOT NULL REFERENCES staging.record_type(record_type) ON DELETE CASCADE,
    filter      jsonb NOT NULL DEFAULT '{}'::jsonb,
    sort_order  integer NOT NULL DEFAULT 10,
    PRIMARY KEY (tab_key, record_type)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON staging.nav_tab_source TO verifier_app;

COMMIT;

SELECT count(*) AS step1_nav_tab_source_rows FROM staging.nav_tab_source;

SELECT 'STEP 2 copy the existing record_type.nav_tab mappings across' AS check;

BEGIN;

INSERT INTO staging.nav_tab_source (tab_key, record_type, filter, sort_order)
SELECT rt.nav_tab, rt.record_type, '{}'::jsonb, 10
FROM staging.record_type rt
WHERE rt.nav_tab IS NOT NULL
ON CONFLICT (tab_key, record_type) DO NOTHING;

COMMIT;

SELECT count(*) AS step2_copied FROM staging.nav_tab_source;

SELECT 'STEP 3 drop the superseded column' AS check;

BEGIN;

ALTER TABLE staging.record_type DROP COLUMN IF EXISTS nav_tab;

COMMIT;

SELECT count(*) AS step3_nav_tab_column_remaining
FROM information_schema.columns
WHERE table_schema = 'staging' AND table_name = 'record_type' AND column_name = 'nav_tab';

SELECT 'STEP 4 register the seven record types' AS check;

BEGIN;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table, field_spec, validation)
VALUES
    ('kw_invoice', 'Building invoice', NULL, 'accounting', 'invoices', '{"fields":[{"editable":true,"label":"Property","name":"property_code","required":true,"type":"enum"},{"editable":true,"label":"Invoice number","name":"invoice_number","required":true,"type":"text"},{"editable":true,"label":"Invoice date","name":"invoice_date","required":true,"type":"date"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":false,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":false,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Payment status","name":"payment_status","required":false,"type":"enum"},{"editable":true,"label":"Description","name":"description","required":false,"type":"text"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["filename"],"party_field":"supplier"}'::jsonb, '{"dropped_on_promotion":["payment_status"],"enums":{"payment_status":["Paid","Unpaid"],"property_code":["115KW","117KW"]},"import_blocks":["duplicate_invoice_number","unknown_party_id"],"promotion_constants":{"direction":"Inwards","status":"reviewed"}}'::jsonb),
    ('elec_main_bill', 'Electricity bill (main meter)', NULL, 'accounting', 'main_meter_bills', '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"text"},{"editable":true,"label":"Invoice number","name":"invoice_number","required":false,"type":"text"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":false,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":false,"type":"text"},{"editable":true,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":false,"type":"text"},{"editable":true,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":true,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":false,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":false,"type":"text"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Total amount due","name":"total_amount_due","required":false,"type":"money"},{"editable":true,"label":"Due date","name":"due_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb, '{"import_blocks":["duplicate_nmi_period"]}'::jsonb),
    ('elec_ind_bill', 'Electricity bill (tenancy meter)', NULL, 'accounting', 'individual_meter_bills', '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"text"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":true,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":true,"type":"text"},{"editable":true,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":true,"type":"text"},{"editable":true,"label":"Level","name":"level","required":true,"type":"text"},{"editable":true,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":true,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":true,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":true,"type":"text"},{"editable":true,"label":"Contract type","name":"contract_type","required":false,"type":"text"},{"editable":true,"label":"Contract status","name":"contract_status","required":false,"type":"text"},{"editable":true,"label":"Avg daily kWh","name":"avg_daily_usage_this_bill_kwh","required":false,"type":"number"},{"editable":true,"label":"Avg daily kWh last year","name":"avg_daily_usage_last_year_kwh","required":false,"type":"number"},{"editable":true,"label":"Meter number","name":"meter_number","required":false,"type":"text"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Direct debit amount","name":"direct_debit_amount","required":false,"type":"money"},{"editable":true,"label":"Direct debit date","name":"direct_debit_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb, '{"import_blocks":["duplicate_nmi_period"]}'::jsonb),
    ('elec_main_charge', 'Main meter charge', 'elec_main_bill', 'accounting', 'main_meter_bill_charges', '{"fields":[{"editable":true,"label":"Charge group","name":"charge_group","required":false,"type":"text"},{"editable":true,"label":"Charge type","name":"charge_type","required":true,"type":"text"},{"editable":true,"label":"Time of use","name":"time_of_use","required":false,"type":"text"},{"editable":true,"label":"Units","name":"units","required":false,"type":"number"},{"editable":true,"label":"Unit type","name":"unit_type","required":false,"type":"text"},{"editable":true,"label":"Rate","name":"rate","required":false,"type":"number"},{"editable":true,"label":"DLF","name":"dlf","required":false,"type":"number"},{"editable":true,"label":"MLF","name":"mlf","required":false,"type":"number"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb, '{}'::jsonb),
    ('elec_ind_charge', 'Tenancy meter charge', 'elec_ind_bill', 'accounting', 'individual_meter_bill_charges', '{"fields":[{"editable":true,"label":"Charge type","name":"charge_type","required":true,"type":"text"},{"editable":true,"label":"Time of use","name":"time_of_use","required":false,"type":"text"},{"editable":true,"label":"Units","name":"units","required":false,"type":"number"},{"editable":true,"label":"Unit type","name":"unit_type","required":false,"type":"text"},{"editable":true,"label":"Rate","name":"rate","required":false,"type":"number"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb, '{}'::jsonb),
    ('elec_main_other_charge', 'Main meter other charge', 'elec_main_bill', 'accounting', 'main_meter_bill_other_charges', '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":true,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb, '{}'::jsonb),
    ('elec_ind_other_charge', 'Tenancy meter other charge', 'elec_ind_bill', 'accounting', 'individual_meter_bill_other_charges', '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":true,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb, '{}'::jsonb)
ON CONFLICT (record_type) DO NOTHING;

COMMIT;

SELECT count(*) AS step4_record_types FROM staging.record_type;

SELECT 'STEP 5 map the new types onto their tabs' AS check;

BEGIN;

INSERT INTO staging.nav_tab_source (tab_key, record_type, filter, sort_order)
VALUES
    ('invoices_115kw', 'kw_invoice', '{"property_code":"115KW"}'::jsonb, 10),
    ('invoices_115kw', 'elec_main_bill', '{}'::jsonb, 20),
    ('invoices_115kw', 'elec_ind_bill', '{}'::jsonb, 30),
    ('invoices_117kw', 'kw_invoice', '{"property_code":"117KW"}'::jsonb, 10)
ON CONFLICT (tab_key, record_type) DO NOTHING;

COMMIT;

SELECT tab_key, count(*) AS sources FROM staging.nav_tab_source
GROUP BY tab_key ORDER BY tab_key;

SELECT 'STEP 6 final read-only verification across all committed steps' AS check;

DO $$
DECLARE
    v_types integer;
    v_sources integer;
    v_cafe integer;
    v_kw_tabs integer;
    v_orphan_children integer;
BEGIN
    SELECT count(*) INTO v_types FROM staging.record_type;
    IF v_types <> 9 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 9 record types (2 cafe + 7 new), found %', v_types;
    END IF;

    SELECT count(*) INTO v_sources FROM staging.nav_tab_source;
    IF v_sources <> 5 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 5 tab sources, found %', v_sources;
    END IF;

    SELECT count(*) INTO v_cafe FROM staging.nav_tab_source
    WHERE tab_key = 'invoices_cafe' AND record_type = 'cafe_invoice';
    IF v_cafe <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the cafe mapping did not survive the column drop';
    END IF;

    SELECT count(*) INTO v_kw_tabs FROM staging.nav_tab_source WHERE record_type = 'kw_invoice';
    IF v_kw_tabs <> 2 THEN
        RAISE EXCEPTION 'ASSERT FAILED: kw_invoice is on % tab(s), expected 2', v_kw_tabs;
    END IF;

    SELECT count(*) INTO v_orphan_children
    FROM staging.record_type rt
    JOIN staging.nav_tab_source s ON s.record_type = rt.record_type
    WHERE rt.parent_type IS NOT NULL;
    IF v_orphan_children <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: % child type(s) mapped to a tab of their own',
            v_orphan_children;
    END IF;

    RAISE NOTICE 'ASSERT OK: 9 types, 5 tab sources, cafe mapping preserved, kw_invoice on 2 tabs, no child tabs';
END
$$;

SELECT 'STEP 7 migration 007 complete' AS check;
