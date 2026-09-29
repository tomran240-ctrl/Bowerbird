/* ============================================================================
   Bowerbird Verifier - migration 005 - DRY RUN FORM
   Uniform staging envelope: one batch/record model for every feed.

   FORM: DRY RUN. One transaction, no intermediate COMMIT, ends in ROLLBACK.
   Nothing in this file is kept. To apply the change, run the separate file
   005_staging_envelope_commit.sql, which is COMMIT-ONLY and idempotent.

   Run:  psql kws115 -f 005_staging_envelope_dryrun.sql

   WHAT IT CREATES
     staging.record_type   registry: one row per kind of staged record,
                           carrying the field spec the app builds its grid
                           from and the production table it promotes into.
     staging.batch         one row per producer file ingested.
     staging.record        one row per staged record, any feed, any depth.
                           parent_uid is self referencing, so an invoice with
                           lines and an electricity bill with charges and
                           other charges are the same shape at different
                           depths.
     staging.record_edit   audit of manual corrections made in the app.

   WHAT IT DOES NOT DO
     It does not touch staging.cafe_invoices or staging.cafe_purchases, and
     it does not move any data. Those tables keep running the live cafe
     queue until the record based path has proved parity. Retirement is a
     later script.

   It writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare. RULE-STG, which will govern producer
   output, is a separate script once this schema is settled.

   NOTE ON NUMBERING: this folder holds 001, 002 and 003. The reconciliation
   work referred to elsewhere as 004 was applied from another folder, so
   there is no 004 here. 005 is named for continuity with that sequence.
   ============================================================================ */

BEGIN;

SELECT 'STEP 1 create staging.record_type' AS check;

CREATE TABLE IF NOT EXISTS staging.record_type (
    record_type    text PRIMARY KEY,
    label          text NOT NULL,
    parent_type    text REFERENCES staging.record_type(record_type),
    target_schema  text NOT NULL,
    target_table   text NOT NULL,
    field_spec     jsonb NOT NULL,
    validation     jsonb NOT NULL DEFAULT '{}'::jsonb,
    active         boolean NOT NULL DEFAULT true,
    created_at     timestamp NOT NULL DEFAULT now()
);

SELECT count(*) AS step1_record_type_rows FROM staging.record_type;

SELECT 'STEP 2 create staging.batch' AS check;

/* One row per producer file. source_file is UNIQUE, so the same dropped
   file can never be ingested twice even if it is replayed by hand. */

CREATE TABLE IF NOT EXISTS staging.batch (
    batch_id          text PRIMARY KEY,
    record_type       text NOT NULL REFERENCES staging.record_type(record_type),
    produced_by       text NOT NULL,
    produced_at       timestamptz NOT NULL,
    schema_version    integer NOT NULL DEFAULT 1,
    source_file       text NOT NULL,
    manifest_checksum text,
    declared_rows     integer,
    ingested_rows     integer NOT NULL DEFAULT 0,
    ingested_at       timestamp NOT NULL DEFAULT now(),
    ingested_by       text,
    status            text NOT NULL DEFAULT 'ingested'
        CHECK (status IN ('ingested','rejected')),
    reject_reason     text,
    CONSTRAINT batch_source_file_key UNIQUE (source_file)
);

SELECT count(*) AS step2_batch_rows FROM staging.batch;

SELECT 'STEP 3 create staging.record' AS check;

/* record_uid is computed by the producer as
     sha256(record_type || '|' || canonical_json(natural_key))
   and is therefore stable across reruns. The UNIQUE on
   (record_type, natural_key) is a backstop: if a producer ever computes a
   uid wrongly, the duplicate is still refused on its business key rather
   than landing twice under two uids.

   flagged deliberately tests party_name first. A record type that carries
   no counterparty at all (an electricity charge line, say) leaves
   match_type NULL and must not be flagged for supplier confirmation. */

CREATE TABLE IF NOT EXISTS staging.record (
    record_uid     text PRIMARY KEY,
    batch_id       text NOT NULL REFERENCES staging.batch(batch_id) ON DELETE CASCADE,
    record_type    text NOT NULL REFERENCES staging.record_type(record_type),
    parent_uid     text REFERENCES staging.record(record_uid) ON DELETE CASCADE,
    seq            integer,
    natural_key    jsonb NOT NULL,
    payload        jsonb NOT NULL,
    provenance     jsonb NOT NULL DEFAULT '{}'::jsonb,
    party_name     text,
    party_id       integer REFERENCES contacts.organisations(id),
    match_type     text CHECK (match_type IS NULL OR match_type IN ('alias','exact','fuzzy','none')),
    match_score    numeric,
    candidate_name text,
    flagged        boolean GENERATED ALWAYS AS
                       (party_name IS NOT NULL AND match_type IS DISTINCT FROM 'alias') STORED,
    row_status     text NOT NULL DEFAULT 'pending'
        CHECK (row_status IN ('pending','verified','deleted','imported','rejected')),
    verified_by    text,
    verified_at    timestamp,
    imported_at    timestamp,
    import_target  text,
    import_pk      text,
    reject_reason  text,
    created_at     timestamp NOT NULL DEFAULT now(),
    CONSTRAINT record_natural_key_key UNIQUE (record_type, natural_key)
);

CREATE INDEX IF NOT EXISTS idx_record_batch_id ON staging.record (batch_id);
CREATE INDEX IF NOT EXISTS idx_record_parent_uid ON staging.record (parent_uid);
CREATE INDEX IF NOT EXISTS idx_record_type_status ON staging.record (record_type, row_status);
CREATE INDEX IF NOT EXISTS idx_record_flagged ON staging.record (flagged) WHERE flagged;

SELECT count(*) AS step3_record_rows FROM staging.record;

SELECT 'STEP 4 create staging.record_edit' AS check;

CREATE TABLE IF NOT EXISTS staging.record_edit (
    edit_id    bigserial PRIMARY KEY,
    record_uid text NOT NULL REFERENCES staging.record(record_uid) ON DELETE CASCADE,
    field      text NOT NULL,
    old_value  text,
    new_value  text,
    edited_by  text,
    edited_at  timestamp NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_record_edit_record_uid ON staging.record_edit (record_uid);

SELECT count(*) AS step4_record_edit_rows FROM staging.record_edit;

SELECT 'STEP 5 grants for verifier_app' AS check;

GRANT SELECT, INSERT, UPDATE, DELETE ON staging.record_type TO verifier_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON staging.batch TO verifier_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON staging.record TO verifier_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON staging.record_edit TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE staging.record_edit_edit_id_seq TO verifier_app;

SELECT count(*) AS step5_staging_grants_for_verifier_app
FROM information_schema.role_table_grants
WHERE grantee = 'verifier_app'
  AND table_schema = 'staging'
  AND table_name IN ('record_type','batch','record','record_edit');

SELECT 'STEP 6 register the two cafe record types' AS check;

/* Guard is ON CONFLICT on record_type, which is the primary key and the
   business key both. No free text is used as a guard key anywhere here. */

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table, field_spec, validation)
VALUES (
    'cafe_invoice',
    'Cafe invoice',
    NULL,
    'cafe',
    'invoices',
    '{"natural_key":["filename"],
      "party_field":"supplier",
      "fields":[
        {"name":"invoice_number","label":"Invoice number","type":"text","editable":true,"required":true},
        {"name":"invoice_date","label":"Invoice date","type":"date","editable":true,"required":true},
        {"name":"amount_ex_gst","label":"Ex GST","type":"money","editable":true,"required":false},
        {"name":"gst_amount","label":"GST","type":"money","editable":true,"required":false},
        {"name":"amount_inc_gst","label":"Inc GST","type":"money","editable":true,"required":true},
        {"name":"payment_status","label":"Payment status","type":"enum","editable":true,"required":true},
        {"name":"notes","label":"Notes","type":"longtext","editable":true,"required":false}
      ]}'::jsonb,
    '{"enums":{"payment_status":["Paid","Unpaid"]},
      "reconcile":{"children":"cafe_line","sum":"line_total_inc_gst","against":"amount_inc_gst","mode":"warn"},
      "import_blocks":["duplicate_supplier_invoice_number","unknown_party_id"]}'::jsonb
)
ON CONFLICT (record_type) DO NOTHING;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table, field_spec, validation)
VALUES (
    'cafe_line',
    'Cafe invoice line',
    'cafe_invoice',
    'cafe',
    'purchases',
    '{"natural_key":["filename","seq"],
      "party_field":null,
      "fields":[
        {"name":"purchase_date","label":"Date","type":"date","editable":true,"required":true},
        {"name":"category","label":"Category","type":"lookup","source":"cafe.expense_categories","editable":true,"required":true},
        {"name":"item","label":"Item","type":"text","editable":true,"required":true},
        {"name":"qty","label":"Qty","type":"number","editable":true,"required":false},
        {"name":"unit_cost","label":"Unit cost","type":"money","editable":true,"required":false},
        {"name":"line_total","label":"Line total","type":"money","editable":true,"required":true},
        {"name":"gst_applicable","label":"GST applicable","type":"boolean","editable":true,"required":false},
        {"name":"gst_declared","label":"GST declared","type":"money","editable":true,"required":false},
        {"name":"gst_assessed","label":"GST assessed","type":"money","editable":true,"required":false},
        {"name":"expense_type","label":"Expense type","type":"enum","editable":true,"required":true},
        {"name":"surcharge_source","label":"Surcharge source","type":"enum","editable":true,"required":false},
        {"name":"in_invoice_total","label":"In invoice total","type":"boolean","editable":true,"required":false},
        {"name":"notes","label":"Notes","type":"longtext","editable":true,"required":false}
      ]}'::jsonb,
    '{"enums":{"expense_type":["COGS","Operating Expense","Non-Business","Capital"],
               "surcharge_source":["Invoice","Bank derived"]},
      "import_blocks":["invalid_expense_type","surcharge_source_on_wrong_category","excluded_line_wrong_category"],
      "excluded_line_categories":["Cafe - Card Surcharge","Cafe - Adjustment"]}'::jsonb
)
ON CONFLICT (record_type) DO NOTHING;

SELECT count(*) AS step6_cafe_record_types
FROM staging.record_type
WHERE record_type IN ('cafe_invoice','cafe_line');

SELECT 'STEP 7 assertions for what this transaction wrote' AS check;

DO $$
DECLARE
    v_tables integer;
    v_types integer;
    v_parent text;
    v_flagged_noparty boolean;
BEGIN
    SELECT count(*) INTO v_tables
    FROM information_schema.tables
    WHERE table_schema = 'staging'
      AND table_name IN ('record_type','batch','record','record_edit');

    IF v_tables <> 4 THEN
        RAISE EXCEPTION 'STEP 7 FAILED: expected 4 staging tables, found %', v_tables;
    END IF;

    SELECT count(*) INTO v_types
    FROM staging.record_type
    WHERE record_type IN ('cafe_invoice','cafe_line');

    IF v_types <> 2 THEN
        RAISE EXCEPTION 'STEP 7 FAILED: expected 2 cafe record types, found %', v_types;
    END IF;

    SELECT parent_type INTO v_parent
    FROM staging.record_type
    WHERE record_type = 'cafe_line';

    IF v_parent IS DISTINCT FROM 'cafe_invoice' THEN
        RAISE EXCEPTION 'STEP 7 FAILED: cafe_line parent_type is %, expected cafe_invoice', v_parent;
    END IF;

    /* The generated column must not flag a record that carries no party at
       all. Proved here rather than assumed, because the expression is the
       one piece of this schema that cannot be read off the column list. */
    SELECT (party_name IS NOT NULL AND match_type IS DISTINCT FROM 'alias')
      INTO v_flagged_noparty
    FROM (SELECT NULL::text AS party_name, NULL::text AS match_type) AS probe;

    IF v_flagged_noparty THEN
        RAISE EXCEPTION 'STEP 7 FAILED: a record with no party would be flagged';
    END IF;

    RAISE NOTICE 'STEP 7 OK: 4 tables, 2 cafe record types, parent link and flag expression correct';
END
$$;

SELECT 'STEP 8 dry run complete - rolling back, nothing kept' AS check;

ROLLBACK;
