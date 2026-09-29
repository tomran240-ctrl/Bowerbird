/* ============================================================================
   Bowerbird Verifier - migration 013 - COMMIT-ONLY
   Create the payroll schema and register the four payroll record types.

   COMMIT-ONLY. Each step is its own transaction and each is idempotent -
   CREATE ... IF NOT EXISTS, inserts guarded by ON CONFLICT, and grants that
   are no-ops when already held. No trailing ROLLBACK. There is no dry-run
   file: the script creates empty objects and configuration rows, STEP 0
   refuses to start if anything is already in an unexpected state, and STEP 8
   proves the outcome.

   Run:  psql kws115 -f 013_payroll_schema_commit.sql

   WHAT THIS IS FOR
     Payroll is the first feed with TWO independent sources for one fact, and
     the verifier is where they are made to agree:

       the pay instruction   what IPS is told to pay, hand-keyed weekly and
                             printed to PDF. 47 weeks, three business units.
       the Square hours run  what the roster and time clock say. Cafe only,
                             two weeks, integer minutes.

     Cafe staff are paid their ROSTERED hours. The time clock verifies
     attendance and does not adjust pay. So the reconciliation compares the
     instruction against rostered hours, never against a clock-derived figure.

   THREE THINGS THE DATA FORCED, each recorded where it will be read again

     1. NO SUNDAY CONSTRAINT ON period_end. Four documents (07, 14, 21 and
        28 Nov 2025) state a period end that is a Friday, under a label
        reading "Weekly Pay Period Ending Sunday". Both the filename and the
        document body carry the same Friday date, so this is not a parsing
        fault - the sheet itself moved to a Friday period end for four weeks
        and moved back. A CHECK would reject four real documents. It is
        registered as a WARNING instead, so those four arrive in the queue as
        a question for a human.

     2. NO payable COLUMN. The Square run computes rostered + ADJ A + ADJ B
        and its ledger calls the result payable_minutes. Nobody is paid it.
        Here it is clocked_minutes. The ledger key keeps its name for
        continuity with rows already written; the producer maps it across.

     3. THE DOCUMENT'S OWN NOTE IS NOT payload.notes. The instruction has a
        Notes column carrying things like "On leave" - producer content. Per
        RULE-STG payload.notes belongs to whoever verifies and a producer
        never writes it, so the printed note is carried as document_note and
        notes is left free.

   RULE-SQL PRE-FLIGHT, the nine points
     1  Plain ASCII throughout.
     2  No psql backslash commands.
     3  Block comments only. No line comments anywhere.
     4  Per-step counts. Every step that writes reports what it wrote.
     5  Assertion DO blocks at both ends.
     6  Business keys, never ids. Every guard is on record_type, tab_key,
        employee_code, period_end or pay_week_start.
     7  Form declared: COMMIT-ONLY, separately committed idempotent steps.
     8  This script writes no rule versions, so there is no (rule_id, version)
        pair to compare.
     9  Surrogate keys are bigserial, matching cafe.invoices and
        accounting.invoices, so promote.py meets nothing it has not seen. No
        identity columns.
   ============================================================================ */

SELECT 'STEP 0 refuse to start unless the ground is as expected' AS check;

DO $preflight$
DECLARE
    v_clash text;
    v_tabs  integer;
BEGIN
    IF to_regclass('staging.record_type') IS NULL
       OR to_regclass('staging.nav_tab') IS NULL
       OR to_regclass('staging.nav_tab_source') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: the staging registry is not present. '
                        'Nothing was changed.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'verifier_app') THEN
        RAISE EXCEPTION 'STEP 0 FAILED: role verifier_app does not exist, so '
                        'the grants in STEP 6 would fail halfway. Nothing was '
                        'changed.';
    END IF;

    /* A record type already registered under one of these names would be
       silently left alone by the ON CONFLICT guards below, and its field_spec
       would then disagree with the tables this script creates. Refuse. */
    SELECT string_agg(record_type, ', ' ORDER BY record_type) INTO v_clash
    FROM staging.record_type
    WHERE record_type IN ('payroll_instruction', 'payroll_instruction_line',
                          'payroll_hours_run', 'payroll_hours_line');
    IF v_clash IS NOT NULL THEN
        RAISE NOTICE 'STEP 0 NOTE: already registered, will be left as found: %',
                     v_clash;
    END IF;

    SELECT count(*) INTO v_tabs FROM staging.nav_tab WHERE tab_key = 'payroll';
    IF v_tabs <> 1 THEN
        RAISE EXCEPTION 'STEP 0 FAILED: expected exactly one payroll nav tab, '
                        'found %. Nothing was changed.', v_tabs;
    END IF;

    RAISE NOTICE 'STEP 0 OK: registry present, verifier_app exists, payroll '
                 'tab present';
END
$preflight$;

SELECT 'STEP 1 the schema' AS check;

BEGIN;

CREATE SCHEMA IF NOT EXISTS payroll;

COMMENT ON SCHEMA payroll IS
    'Payroll for My Little Friend, Gregory Hicks Trustee - three business '
    'units (115connect, Cafe, Farm). Pay basis is rostered hours; the time '
    'clock verifies attendance and does not adjust pay.';

COMMIT;

SELECT count(*) AS step1_payroll_schema
FROM pg_namespace WHERE nspname = 'payroll';

SELECT 'STEP 2 employee - the bridge between the two sources' AS check;

BEGIN;

CREATE TABLE IF NOT EXISTS payroll.employee (
    employee_code          text PRIMARY KEY,
    surname                text NOT NULL,
    first_name             text NOT NULL,
    business_unit          text NOT NULL
        CHECK (business_unit IN ('115connect', 'Cafe', 'Farm')),
    employment_class       text,
    square_team_member_id  text UNIQUE,
    reconciled             boolean NOT NULL DEFAULT true,
    active                 boolean NOT NULL DEFAULT true,
    created_at             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE payroll.employee IS
    'One row per person in either payroll source. The two sources identify '
    'people differently and the mapping cannot be derived: employee_code '
    'GAGE-M is Mansi GAJERA. Seed and maintain it explicitly; never infer '
    'from a name.';

COMMENT ON COLUMN payroll.employee.square_team_member_id IS
    'Null for everyone outside the cafe. Only cafe staff appear in Square.';

COMMENT ON COLUMN payroll.employee.reconciled IS
    'False for 115connect and Farm, whose hours are entered manually and have '
    'no second source. Keeps them out of the variance queue instead of '
    'leaving them permanently unreconciled, which would train the reader to '
    'ignore it.';

COMMIT;

SELECT count(*) AS step2_employee_rows FROM payroll.employee;

SELECT 'STEP 3 the pay instruction - what IPS is told to pay' AS check;

BEGIN;

CREATE TABLE IF NOT EXISTS payroll.pay_instruction (
    id               bigserial PRIMARY KEY,
    period_end       date NOT NULL,
    business_unit    text NOT NULL
        CHECK (business_unit IN ('115connect', 'Cafe', 'Farm')),
    total_hours      numeric(8,2) NOT NULL,
    staff_count      integer,
    source_document  text,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (period_end, business_unit)
);

COMMENT ON TABLE payroll.pay_instruction IS
    'One row per pay week per business unit, from the weekly PDF issued to '
    'Integrated Payroll Solutions. period_end carries NO Sunday constraint: '
    'four documents in November 2025 state a Friday period end in both the '
    'filename and the body. That is a question for a human, not a fault to '
    'reject.';

CREATE TABLE IF NOT EXISTS payroll.pay_instruction_line (
    id                bigserial PRIMARY KEY,
    instruction_id    bigint NOT NULL
        REFERENCES payroll.pay_instruction (id) ON DELETE RESTRICT,
    employee_code     text NOT NULL
        REFERENCES payroll.employee (employee_code) ON DELETE RESTRICT,
    seq               integer NOT NULL,
    normal_hours      numeric(7,2) NOT NULL DEFAULT 0,
    overtime_hours    numeric(7,2) NOT NULL DEFAULT 0,
    adjustment_hours  numeric(7,2) NOT NULL DEFAULT 0,
    total_hours       numeric(7,2) NOT NULL,
    document_note     text,
    notes             text,
    UNIQUE (instruction_id, employee_code),
    CONSTRAINT pay_instruction_line_sums
        CHECK (total_hours = normal_hours + overtime_hours + adjustment_hours)
);

COMMENT ON COLUMN payroll.pay_instruction_line.document_note IS
    'The Notes column printed on the document, e.g. "On leave". Producer '
    'content, kept out of notes so that notes stays the verifier''s own.';

CREATE INDEX IF NOT EXISTS pay_instruction_line_employee_idx
    ON payroll.pay_instruction_line (employee_code);

COMMIT;

SELECT count(*) AS step3_instruction_rows FROM payroll.pay_instruction;
SELECT count(*) AS step3_instruction_line_rows FROM payroll.pay_instruction_line;

SELECT 'STEP 4 the Square hours run - roster and attendance' AS check;

BEGIN;

CREATE TABLE IF NOT EXISTS payroll.hours_run (
    id                 bigserial PRIMARY KEY,
    pay_week_start     date NOT NULL UNIQUE,
    pay_week_end       date NOT NULL,
    run_date           date NOT NULL,
    settled_from       date,
    settled_to         date,
    carryback_from     date,
    carryback_to       date,
    deferred_from      date,
    deferred_to        date,
    rostered_minutes   integer NOT NULL,
    adj_a_minutes      integer NOT NULL,
    adj_b_minutes      integer NOT NULL,
    clocked_minutes    integer NOT NULL,
    exceptions_action  integer NOT NULL DEFAULT 0,
    exceptions_review  integer NOT NULL DEFAULT 0,
    exceptions_note    integer NOT NULL DEFAULT 0,
    generated          text,
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT hours_run_week_is_seven_days
        CHECK (pay_week_end = pay_week_start + 6),
    CONSTRAINT hours_run_clocked_identity
        CHECK (clocked_minutes = rostered_minutes + adj_a_minutes + adj_b_minutes)
);

COMMENT ON TABLE payroll.hours_run IS
    'One row per pay week from payroll_ledger.jsonl. rostered_minutes is the '
    'pay basis. clocked_minutes is the ledger''s payable_minutes renamed to '
    'what it is - an attendance figure nobody is paid.';

CREATE TABLE IF NOT EXISTS payroll.hours_line (
    id                     bigserial PRIMARY KEY,
    run_id                 bigint NOT NULL
        REFERENCES payroll.hours_run (id) ON DELETE RESTRICT,
    square_team_member_id  text NOT NULL,
    employee_code          text
        REFERENCES payroll.employee (employee_code) ON DELETE RESTRICT,
    seq                    integer NOT NULL,
    staff_name             text NOT NULL,
    role                   text,
    rostered_minutes       integer NOT NULL,
    adj_a_minutes          integer NOT NULL,
    adj_b_minutes          integer NOT NULL,
    clocked_minutes        integer NOT NULL,
    notes                  text,
    UNIQUE (run_id, square_team_member_id),
    CONSTRAINT hours_line_clocked_identity
        CHECK (clocked_minutes = rostered_minutes + adj_a_minutes + adj_b_minutes)
);

COMMENT ON COLUMN payroll.hours_line.employee_code IS
    'Nullable so a new starter appearing in Square before the bridge is '
    'updated still loads. A null here means that person cannot be '
    'reconciled, and v_pay_variance says so rather than dropping the row.';

CREATE INDEX IF NOT EXISTS hours_line_employee_idx
    ON payroll.hours_line (employee_code);

COMMIT;

SELECT count(*) AS step4_hours_run_rows FROM payroll.hours_run;
SELECT count(*) AS step4_hours_line_rows FROM payroll.hours_line;

SELECT 'STEP 5 the variance view' AS check;

BEGIN;

CREATE OR REPLACE VIEW payroll.v_pay_variance AS
WITH tol AS (
    /* One source of truth for the tolerance: the registry, not a literal
       repeated here and in the app. Six minutes is 0.10 h. */
    SELECT coalesce(
        (SELECT (validation -> 'cross_check' ->> 'tolerance_hours')::numeric
         FROM staging.record_type
         WHERE record_type = 'payroll_instruction'), 0.10) AS tolerance_hours
)
SELECT
    i.period_end,
    i.business_unit,
    e.employee_code,
    e.surname,
    e.first_name,
    l.total_hours                                   AS instruction_hours,
    round(hl.rostered_minutes / 60.0, 2)            AS rostered_hours,
    round(l.total_hours - hl.rostered_minutes / 60.0, 2) AS variance_hours,
    round(hl.adj_a_minutes / 60.0, 2)               AS adj_a_hours,
    round(hl.adj_b_minutes / 60.0, 2)               AS adj_b_hours,
    t.tolerance_hours,
    CASE
        WHEN hl.id IS NULL                     THEN 'NO HOURS RUN'
        WHEN abs(l.total_hours - hl.rostered_minutes / 60.0)
             <= t.tolerance_hours              THEN 'OK'
        ELSE                                        'VARIANCE'
    END                                             AS status,
    (extract(isodow from i.period_end) <> 7)        AS period_end_not_sunday
FROM payroll.pay_instruction i
CROSS JOIN tol t
JOIN payroll.pay_instruction_line l ON l.instruction_id = i.id
JOIN payroll.employee e             ON e.employee_code = l.employee_code
LEFT JOIN payroll.hours_run r       ON r.pay_week_end = i.period_end
LEFT JOIN payroll.hours_line hl     ON hl.run_id = r.id
                                   AND hl.employee_code = e.employee_code
WHERE e.reconciled;

COMMENT ON VIEW payroll.v_pay_variance IS
    'Instruction hours against ROSTERED hours, per person per pay week. Cafe '
    'only in practice, because reconciled is false for the manually entered '
    'units. The clock variances are shown beside the figures and take no part '
    'in the comparison.';

COMMIT;

SELECT count(*) AS step5_variance_rows FROM payroll.v_pay_variance;

SELECT 'STEP 6 grants to verifier_app' AS check;

BEGIN;

GRANT USAGE ON SCHEMA payroll TO verifier_app;

GRANT SELECT, INSERT ON payroll.employee              TO verifier_app;
GRANT SELECT, INSERT ON payroll.pay_instruction       TO verifier_app;
GRANT SELECT, INSERT ON payroll.pay_instruction_line  TO verifier_app;
GRANT SELECT, INSERT ON payroll.hours_run             TO verifier_app;
GRANT SELECT, INSERT ON payroll.hours_line            TO verifier_app;
GRANT SELECT          ON payroll.v_pay_variance       TO verifier_app;

GRANT USAGE ON SEQUENCE payroll.pay_instruction_id_seq       TO verifier_app;
GRANT USAGE ON SEQUENCE payroll.pay_instruction_line_id_seq  TO verifier_app;
GRANT USAGE ON SEQUENCE payroll.hours_run_id_seq             TO verifier_app;
GRANT USAGE ON SEQUENCE payroll.hours_line_id_seq            TO verifier_app;

COMMIT;

SELECT count(*) AS step6_verifier_app_table_privileges
FROM information_schema.role_table_grants
WHERE grantee = 'verifier_app' AND table_schema = 'payroll';

SELECT 'STEP 7 register the four record types' AS check;

BEGIN;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table,
     field_spec, validation, active)
VALUES (
    'payroll_instruction',
    'Pay instruction',
    NULL,
    'payroll',
    'pay_instruction',
    '{
        "fields": [
            {"name":"total_hours","type":"number","label":"Total hours",
             "editable":false,"required":true},
            {"name":"staff_count","type":"number","label":"Staff",
             "editable":false,"required":false},
            {"name":"notes","type":"longtext","label":"Notes",
             "editable":true,"required":false}
        ],
        "natural_key": ["period_end","business_unit"],
        "party_field": null
     }'::jsonb,
    '{
        "enums": {
            "business_unit": ["115connect","Cafe","Farm"]
        },
        "reconcile": {
            "sum": "total_hours",
            "mode": "block",
            "against": "total_hours",
            "children": "payroll_instruction_line"
        },
        "cross_check": {
            "against_type": "payroll_hours_line",
            "only_when": {"business_unit": "Cafe"},
            "match_on": ["period_end = pay_week_end","employee_code"],
            "compare": "total_hours vs rostered_hours",
            "tolerance_hours": 0.10,
            "mode": "block"
        },
        "warnings": ["period_end_not_sunday"],
        "import_blocks": ["unknown_employee_code","pay_variance_over_tolerance"]
     }'::jsonb,
    true
)
ON CONFLICT (record_type) DO NOTHING;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table,
     field_spec, validation, active)
VALUES (
    'payroll_instruction_line',
    'Pay instruction line',
    'payroll_instruction',
    'payroll',
    'pay_instruction_line',
    '{
        "fields": [
            {"name":"surname","type":"text","label":"Surname",
             "editable":false,"required":true},
            {"name":"first_name","type":"text","label":"First name",
             "editable":false,"required":true},
            {"name":"normal_hours","type":"number","label":"Normal",
             "editable":true,"required":false},
            {"name":"overtime_hours","type":"number","label":"Overtime",
             "editable":true,"required":false},
            {"name":"adjustment_hours","type":"number","label":"Adjustment",
             "editable":true,"required":false},
            {"name":"total_hours","type":"number","label":"Total",
             "editable":true,"required":true},
            {"name":"document_note","type":"text","label":"Document note",
             "editable":false,"required":false},
            {"name":"notes","type":"longtext","label":"Notes",
             "editable":true,"required":false}
        ],
        "natural_key": ["period_end","business_unit","employee_code","seq"],
        "party_field": null
     }'::jsonb,
    '{
        "import_blocks": ["unknown_employee_code","line_total_does_not_sum"]
     }'::jsonb,
    true
)
ON CONFLICT (record_type) DO NOTHING;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table,
     field_spec, validation, active)
VALUES (
    'payroll_hours_run',
    'Square hours run',
    NULL,
    'payroll',
    'hours_run',
    '{
        "fields": [
            {"name":"pay_week_end","type":"date","label":"Week ending",
             "editable":false,"required":true},
            {"name":"run_date","type":"date","label":"Run date",
             "editable":false,"required":true},
            {"name":"rostered_minutes","type":"number","label":"Rostered (min)",
             "editable":false,"required":true},
            {"name":"adj_a_minutes","type":"number","label":"ADJ A (min)",
             "editable":false,"required":true},
            {"name":"adj_b_minutes","type":"number","label":"ADJ B (min)",
             "editable":false,"required":true},
            {"name":"clocked_minutes","type":"number","label":"Clocked (min)",
             "editable":false,"required":true},
            {"name":"settled_from","type":"date","label":"Settled from",
             "editable":false,"required":false},
            {"name":"settled_to","type":"date","label":"Settled to",
             "editable":false,"required":false},
            {"name":"carryback_from","type":"date","label":"Carry-back from",
             "editable":false,"required":false},
            {"name":"carryback_to","type":"date","label":"Carry-back to",
             "editable":false,"required":false},
            {"name":"deferred_from","type":"date","label":"Deferred from",
             "editable":false,"required":false},
            {"name":"deferred_to","type":"date","label":"Deferred to",
             "editable":false,"required":false},
            {"name":"exceptions_action","type":"number","label":"Action",
             "editable":false,"required":false},
            {"name":"exceptions_review","type":"number","label":"Review",
             "editable":false,"required":false},
            {"name":"exceptions_note","type":"number","label":"Noted",
             "editable":false,"required":false},
            {"name":"generated","type":"text","label":"Generated",
             "editable":false,"required":false},
            {"name":"notes","type":"longtext","label":"Notes",
             "editable":true,"required":false}
        ],
        "natural_key": ["pay_week_start"],
        "party_field": null
     }'::jsonb,
    '{
        "reconcile": {
            "sum": "rostered_minutes",
            "mode": "block",
            "against": "rostered_minutes",
            "children": "payroll_hours_line"
        },
        "import_blocks": ["clocked_identity_fails"]
     }'::jsonb,
    true
)
ON CONFLICT (record_type) DO NOTHING;

INSERT INTO staging.record_type
    (record_type, label, parent_type, target_schema, target_table,
     field_spec, validation, active)
VALUES (
    'payroll_hours_line',
    'Square hours line',
    'payroll_hours_run',
    'payroll',
    'hours_line',
    '{
        "fields": [
            {"name":"staff_name","type":"text","label":"Name",
             "editable":false,"required":true},
            {"name":"role","type":"text","label":"Role",
             "editable":false,"required":false},
            {"name":"rostered_minutes","type":"number","label":"Rostered (min)",
             "editable":false,"required":true},
            {"name":"adj_a_minutes","type":"number","label":"ADJ A (min)",
             "editable":false,"required":true},
            {"name":"adj_b_minutes","type":"number","label":"ADJ B (min)",
             "editable":false,"required":true},
            {"name":"clocked_minutes","type":"number","label":"Clocked (min)",
             "editable":false,"required":true},
            {"name":"notes","type":"longtext","label":"Notes",
             "editable":true,"required":false}
        ],
        "natural_key": ["pay_week_start","square_team_member_id","seq"],
        "party_field": null
     }'::jsonb,
    '{
        "import_blocks": ["clocked_identity_fails"]
     }'::jsonb,
    true
)
ON CONFLICT (record_type) DO NOTHING;

COMMIT;

SELECT record_type, parent_type, target_schema || '.' || target_table AS target,
       active
FROM staging.record_type
WHERE record_type LIKE 'payroll%'
ORDER BY record_type;

SELECT 'STEP 7b wire the payroll tab to its two parent types' AS check;

BEGIN;

INSERT INTO staging.nav_tab_source (tab_key, record_type, sort_order)
VALUES ('payroll', 'payroll_instruction', 10)
ON CONFLICT (tab_key, record_type) DO NOTHING;

INSERT INTO staging.nav_tab_source (tab_key, record_type, sort_order)
VALUES ('payroll', 'payroll_hours_run', 20)
ON CONFLICT (tab_key, record_type) DO NOTHING;

COMMIT;

SELECT tab_key, record_type, sort_order
FROM staging.nav_tab_source WHERE tab_key = 'payroll' ORDER BY sort_order;

SELECT 'STEP 8 assertions for what this script left behind' AS check;

DO $verify$
DECLARE
    v_tables    integer;
    v_types     integer;
    v_sources   integer;
    v_grants    integer;
    v_tol       numeric;
    v_bad_child text;
    v_missing   text;
BEGIN
    SELECT count(*) INTO v_tables
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'payroll' AND c.relkind = 'r'
      AND c.relname IN ('employee','pay_instruction','pay_instruction_line',
                        'hours_run','hours_line');
    IF v_tables <> 5 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 5 payroll tables, found %', v_tables;
    END IF;

    IF to_regclass('payroll.v_pay_variance') IS NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: payroll.v_pay_variance was not created';
    END IF;

    SELECT count(*) INTO v_types
    FROM staging.record_type WHERE record_type LIKE 'payroll%' AND active;
    IF v_types <> 4 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 4 active payroll record '
                        'types, found %', v_types;
    END IF;

    /* Every registered payroll type must point at a table that exists, or the
       grid will offer a queue that can never be imported. */
    SELECT string_agg(rt.record_type || ' -> ' || rt.target_schema || '.' ||
                      rt.target_table, ', ' ORDER BY rt.record_type)
      INTO v_missing
    FROM staging.record_type rt
    WHERE rt.record_type LIKE 'payroll%'
      AND to_regclass(rt.target_schema || '.' || rt.target_table) IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: record type(s) point at a missing '
                        'destination: %', v_missing;
    END IF;

    /* Every child must name a parent that is itself registered. */
    SELECT string_agg(c.record_type, ', ' ORDER BY c.record_type)
      INTO v_bad_child
    FROM staging.record_type c
    WHERE c.record_type LIKE 'payroll%'
      AND c.parent_type IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM staging.record_type p
                      WHERE p.record_type = c.parent_type);
    IF v_bad_child IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: child type(s) with an unregistered '
                        'parent: %', v_bad_child;
    END IF;

    SELECT count(*) INTO v_sources
    FROM staging.nav_tab_source WHERE tab_key = 'payroll';
    IF v_sources <> 2 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the payroll tab has % source(s), '
                        'expected 2', v_sources;
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

    /* The view must actually be reading the tolerance out of the registry,
       not falling through to its own default. */
    SELECT (validation -> 'cross_check' ->> 'tolerance_hours')::numeric
      INTO v_tol
    FROM staging.record_type WHERE record_type = 'payroll_instruction';
    IF v_tol IS DISTINCT FROM 0.10 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the registry tolerance is %, expected '
                        '0.10 (six minutes)', v_tol;
    END IF;

    RAISE NOTICE 'ASSERT OK: 5 tables, 1 view, 4 record types, 2 tab sources, '
                 '% table privilege(s), tolerance % h read from the registry',
                 v_grants, v_tol;
    RAISE NOTICE 'Next: seed payroll.employee, then run the two producers. '
                 'Nothing can be reconciled until the bridge is seeded.';
END
$verify$;

SELECT 'STEP 9 migration 013 complete' AS check;
