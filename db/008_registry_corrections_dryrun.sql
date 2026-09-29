/* ============================================================================
   Bowerbird Verifier - migration 008 - DRY RUN FORM
   Lock natural-key fields, and mirror destination CHECK constraints into the
   registry.

   FORM: DRY RUN. One transaction, no intermediate COMMIT, ends in ROLLBACK.
   Nothing is kept. To apply, run 008_registry_corrections_commit.sql.

   Run:  psql kws115 -f 008_registry_corrections_dryrun.sql

   WHY. A fresh-eyes review of migration 007 and the promote mapper found
   three faults, all of which live in the registry rather than in code:

   1. nmi, bill_period_start and bill_period_end were editable on both bill
      types. record_uid is a hash of natural_key and is frozen at ingest, so
      editing one of those decoupled a record's identity from its content.
      Worse, the promotion duplicate guard read natural_key while the INSERT
      wrote payload, so correcting a mis-read NMI made the guard test one
      tuple and the write use another - straight into the destination's
      UNIQUE constraint, as an abort rather than a reported block. The guard
      now reads payload; these fields become read-only so the two can never
      diverge again.

   2. retailer, read_type, charge_type and unit_type are CHECK-constrained in
      accounting.* but were registered as free text. A typo passed review and
      failed at write. They become enums carrying exactly the values the
      CHECK allows, so the app offers a picker and ingestion refuses the rest.
      Verified against pg_constraint: main_meter_bill_charges and both
      other_charges tables carry no CHECK, so nothing is invented for them.

   3. gst_exempt was required, while its destination column is NOT NULL
      DEFAULT false. One blank cell refused a whole batch of charges. It
      becomes optional and the producer supplies false.

   Only the five affected record types are rewritten. cafe_invoice, cafe_line
   and kw_invoice are untouched, as are all staged records - this changes how
   records are described, never any record.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

BEGIN;

SELECT 'STEP 1 rewrite elec_main_bill' AS check;

UPDATE staging.record_type
SET field_spec = '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"enum"},{"editable":true,"label":"Invoice number","name":"invoice_number","required":false,"type":"text"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":false,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":false,"type":"text"},{"editable":false,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":false,"type":"text"},{"editable":false,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":false,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":false,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":false,"type":"text"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Total amount due","name":"total_amount_due","required":false,"type":"money"},{"editable":true,"label":"Due date","name":"due_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb,
    validation = '{"enums":{"retailer":["Origin Energy","EnergyAustralia","AGL"]},"enums_mirror":"CHECK constraints on accounting.main_meter_bills","import_blocks":["duplicate_nmi_period"]}'::jsonb
WHERE record_type = 'elec_main_bill'
  AND (field_spec IS DISTINCT FROM '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"enum"},{"editable":true,"label":"Invoice number","name":"invoice_number","required":false,"type":"text"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":false,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":false,"type":"text"},{"editable":false,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":false,"type":"text"},{"editable":false,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":false,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":false,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":false,"type":"text"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Total amount due","name":"total_amount_due","required":false,"type":"money"},{"editable":true,"label":"Due date","name":"due_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb OR validation IS DISTINCT FROM '{"enums":{"retailer":["Origin Energy","EnergyAustralia","AGL"]},"enums_mirror":"CHECK constraints on accounting.main_meter_bills","import_blocks":["duplicate_nmi_period"]}'::jsonb);

SELECT count(*) AS step1_rows FROM staging.record_type WHERE record_type = 'elec_main_bill';

SELECT 'STEP 2 rewrite elec_ind_bill' AS check;

UPDATE staging.record_type
SET field_spec = '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"enum"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":true,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":true,"type":"text"},{"editable":false,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":true,"type":"text"},{"editable":true,"label":"Level","name":"level","required":true,"type":"text"},{"editable":false,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":false,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":true,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":true,"type":"enum"},{"editable":true,"label":"Contract type","name":"contract_type","required":false,"type":"text"},{"editable":true,"label":"Contract status","name":"contract_status","required":false,"type":"text"},{"editable":true,"label":"Avg daily kWh","name":"avg_daily_usage_this_bill_kwh","required":false,"type":"number"},{"editable":true,"label":"Avg daily kWh last year","name":"avg_daily_usage_last_year_kwh","required":false,"type":"number"},{"editable":true,"label":"Meter number","name":"meter_number","required":false,"type":"text"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Direct debit amount","name":"direct_debit_amount","required":false,"type":"money"},{"editable":true,"label":"Direct debit date","name":"direct_debit_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb,
    validation = '{"enums":{"read_type":["Actual","Estimate"],"retailer":["AGL","Origin Energy","EnergyAustralia"]},"enums_mirror":"CHECK constraints on accounting.individual_meter_bills","import_blocks":["duplicate_nmi_period"]}'::jsonb
WHERE record_type = 'elec_ind_bill'
  AND (field_spec IS DISTINCT FROM '{"fields":[{"editable":true,"label":"Retailer","name":"retailer","required":true,"type":"enum"},{"editable":true,"label":"Issue date","name":"issue_date","required":true,"type":"date"},{"editable":true,"label":"Account name","name":"account_name","required":true,"type":"text"},{"editable":true,"label":"Account number","name":"account_number","required":true,"type":"text"},{"editable":false,"label":"NMI","name":"nmi","required":true,"type":"text"},{"editable":true,"label":"Invoice type","name":"invoice_type","required":false,"type":"text"},{"editable":true,"label":"Supply address","name":"supply_address","required":true,"type":"text"},{"editable":true,"label":"Level","name":"level","required":true,"type":"text"},{"editable":false,"label":"Period start","name":"bill_period_start","required":true,"type":"date"},{"editable":false,"label":"Period end","name":"bill_period_end","required":true,"type":"date"},{"editable":true,"label":"Period days","name":"bill_period_days","required":true,"type":"number"},{"editable":true,"label":"Read type","name":"read_type","required":true,"type":"enum"},{"editable":true,"label":"Contract type","name":"contract_type","required":false,"type":"text"},{"editable":true,"label":"Contract status","name":"contract_status","required":false,"type":"text"},{"editable":true,"label":"Avg daily kWh","name":"avg_daily_usage_this_bill_kwh","required":false,"type":"number"},{"editable":true,"label":"Avg daily kWh last year","name":"avg_daily_usage_last_year_kwh","required":false,"type":"number"},{"editable":true,"label":"Meter number","name":"meter_number","required":false,"type":"text"},{"editable":true,"label":"Previous balance","name":"previous_balance","required":false,"type":"money"},{"editable":true,"label":"Payment date","name":"payment_date","required":false,"type":"date"},{"editable":true,"label":"Payment amount","name":"payment_amount","required":false,"type":"money"},{"editable":true,"label":"Balance brought forward","name":"balance_brought_forward","required":false,"type":"money"},{"editable":true,"label":"Ex GST","name":"amount_ex_gst","required":true,"type":"money"},{"editable":true,"label":"GST","name":"gst_amount","required":true,"type":"money"},{"editable":true,"label":"Inc GST","name":"amount_inc_gst","required":true,"type":"money"},{"editable":true,"label":"Direct debit amount","name":"direct_debit_amount","required":false,"type":"money"},{"editable":true,"label":"Direct debit date","name":"direct_debit_date","required":false,"type":"date"},{"editable":true,"label":"Your note","name":"notes","required":false,"type":"longtext"}],"natural_key":["nmi","bill_period_start","bill_period_end"],"party_field":"retailer"}'::jsonb OR validation IS DISTINCT FROM '{"enums":{"read_type":["Actual","Estimate"],"retailer":["AGL","Origin Energy","EnergyAustralia"]},"enums_mirror":"CHECK constraints on accounting.individual_meter_bills","import_blocks":["duplicate_nmi_period"]}'::jsonb);

SELECT count(*) AS step2_rows FROM staging.record_type WHERE record_type = 'elec_ind_bill';

SELECT 'STEP 3 rewrite elec_ind_charge' AS check;

UPDATE staging.record_type
SET field_spec = '{"fields":[{"editable":true,"label":"Charge type","name":"charge_type","required":true,"type":"enum"},{"editable":true,"label":"Time of use","name":"time_of_use","required":false,"type":"text"},{"editable":true,"label":"Units","name":"units","required":false,"type":"number"},{"editable":true,"label":"Unit type","name":"unit_type","required":false,"type":"enum"},{"editable":true,"label":"Rate","name":"rate","required":false,"type":"number"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb,
    validation = '{"enums":{"charge_type":["Peak","Off Peak","Shoulder","Supply","Demand"],"unit_type":["kWh","days","kVA"]},"enums_mirror":"CHECK constraints on accounting.individual_meter_bill_charges"}'::jsonb
WHERE record_type = 'elec_ind_charge'
  AND (field_spec IS DISTINCT FROM '{"fields":[{"editable":true,"label":"Charge type","name":"charge_type","required":true,"type":"enum"},{"editable":true,"label":"Time of use","name":"time_of_use","required":false,"type":"text"},{"editable":true,"label":"Units","name":"units","required":false,"type":"number"},{"editable":true,"label":"Unit type","name":"unit_type","required":false,"type":"enum"},{"editable":true,"label":"Rate","name":"rate","required":false,"type":"number"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb OR validation IS DISTINCT FROM '{"enums":{"charge_type":["Peak","Off Peak","Shoulder","Supply","Demand"],"unit_type":["kWh","days","kVA"]},"enums_mirror":"CHECK constraints on accounting.individual_meter_bill_charges"}'::jsonb);

SELECT count(*) AS step3_rows FROM staging.record_type WHERE record_type = 'elec_ind_charge';

SELECT 'STEP 4 rewrite elec_main_other_charge' AS check;

UPDATE staging.record_type
SET field_spec = '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":false,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb,
    validation = '{}'::jsonb
WHERE record_type = 'elec_main_other_charge'
  AND (field_spec IS DISTINCT FROM '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":false,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb OR validation IS DISTINCT FROM '{}'::jsonb);

SELECT count(*) AS step4_rows FROM staging.record_type WHERE record_type = 'elec_main_other_charge';

SELECT 'STEP 5 rewrite elec_ind_other_charge' AS check;

UPDATE staging.record_type
SET field_spec = '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":false,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb,
    validation = '{}'::jsonb
WHERE record_type = 'elec_ind_other_charge'
  AND (field_spec IS DISTINCT FROM '{"fields":[{"editable":true,"label":"Description","name":"description","required":true,"type":"text"},{"editable":true,"label":"Amount","name":"amount","required":true,"type":"money"},{"editable":true,"label":"GST exempt","name":"gst_exempt","required":false,"type":"boolean"}],"natural_key":["nmi","bill_period_start","bill_period_end","seq"],"party_field":null}'::jsonb OR validation IS DISTINCT FROM '{}'::jsonb);

SELECT count(*) AS step5_rows FROM staging.record_type WHERE record_type = 'elec_ind_other_charge';

SELECT 'STEP 6 assertions for what this transaction wrote' AS check;

DO $$
DECLARE
    v_editable integer;
    v_enums integer;
    v_required integer;
BEGIN
    SELECT count(*) INTO v_editable
    FROM staging.record_type rt,
         LATERAL jsonb_array_elements(rt.field_spec->'fields') f
    WHERE rt.record_type IN ('elec_main_bill','elec_ind_bill')
      AND f->>'name' IN ('nmi','bill_period_start','bill_period_end')
      AND (f->>'editable')::boolean;
    IF v_editable <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: % natural-key field(s) are still editable', v_editable;
    END IF;

    SELECT count(*) INTO v_enums
    FROM staging.record_type rt,
         LATERAL jsonb_array_elements(rt.field_spec->'fields') f
    WHERE rt.record_type IN ('elec_main_bill','elec_ind_bill','elec_ind_charge')
      AND f->>'name' IN ('retailer','read_type','charge_type','unit_type')
      AND f->>'type' = 'enum'
      AND rt.validation->'enums' ? (f->>'name');
    IF v_enums <> 5 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 5 CHECK-mirrored enums, found %', v_enums;
    END IF;

    SELECT count(*) INTO v_required
    FROM staging.record_type rt,
         LATERAL jsonb_array_elements(rt.field_spec->'fields') f
    WHERE rt.record_type IN ('elec_main_other_charge','elec_ind_other_charge')
      AND f->>'name' = 'gst_exempt'
      AND (f->>'required')::boolean;
    IF v_required <> 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: gst_exempt is still required on % type(s)', v_required;
    END IF;

    RAISE NOTICE 'ASSERT OK: natural-key fields locked, 5 enums mirrored, gst_exempt optional';
END
$$;

SELECT 'dry run complete - rolling back, nothing kept' AS check;

ROLLBACK;
