/* ============================================================================
   Bowerbird Verifier - migration 012 - COMMIT-ONLY
   Register RULE-STG, the staging envelope contract, in the rule register.

   COMMIT-ONLY. Each step is its own transaction and each is idempotent - the
   rule insert is guarded by ON CONFLICT, the version insert by this script's
   own change_reason marker, the consumer insert by its primary key. No
   trailing ROLLBACK. There is no dry-run file: the script inserts one rule,
   one version and one consumer row, STEP 0 refuses to start if the register
   is not shaped as expected, and STEP 4 proves the outcome. A rollback would
   demonstrate less than the assertions do.

   Run:  psql kws115 -f 012_rule_stg_commit.sql

   WHAT THIS REGISTERS
     RULE-STG is the contract a producer must meet for a record to enter
     kws115 through review. It binds the producer, not the app: the app
     refuses whatever does not meet it. The body embedded below is
     byte-identical to db/RULE-STG-draft-body.txt, so after this runs

         md5 -q db/RULE-STG-draft-body.txt

     must equal the checksum STEP 4 prints.

   TWO CORRECTIONS FOUND AT PRE-FLIGHT, both against pg_catalog
     1  normalisation.rule_versions.checksum is a GENERATED column -
            checksum text GENERATED ALWAYS AS (md5(body)) STORED
        so this script does NOT write it. An INSERT naming checksum fails
        with "cannot insert a non-DEFAULT value into column". The earlier
        finding that checksum = md5(body) on every sampled row was the
        database computing it, not a convention scripts maintain by hand.
     2  normalisation.rules.title is NOT NULL with no default, so the rule
        row carries a title and a scope_note, in the house style: a short
        noun phrase and one sentence of scope.
     Also: superseded_at is date, not timestamptz, so it is set with
     CURRENT_DATE rather than now().

   RULE-SQL PRE-FLIGHT, the nine points
     1  Plain ASCII throughout, the rule body included - it writes "cafe"
        without the accent, and uses no em dash or smart quote.
     2  No psql backslash commands.
     3  Block comments only. No line comments anywhere.
     4  Per-step counts. Every step that writes reports what it wrote.
     5  Assertion DO blocks at both ends: STEP 0 refuses to start on a
        surprise, STEP 4 proves what was left behind.
     6  Business keys, never ids. Everything is keyed on rule_id, version and
        task_id. No surrogate id is read or written.
     7  Form declared: COMMIT-ONLY, separately committed idempotent steps.
     8  The version number is DERIVED, never a literal:
            coalesce(max(version), 0) + 1  for rule_id = 'RULE-STG'
        A grep of db/ for a literal pair
            grep -oE "'RULE-[A-Z0-9]+',[[:space:]]*[0-9]+" *.sql
        returns nothing, so no other script here can race this one to a
        version number. RULE-STG has no rows today, so this resolves to 1.
     9  Idempotency anchored on a marker this script owns: the exact
        change_reason string, compared with equality rather than a prefix, so
        another script committed on the same date cannot be mistaken for it.

   NO defect_ref, DELIBERATELY.
     RULE-SQL requires a defect id to name its task and to resolve to a block
     in the defects folder, and I cannot see that folder to verify one. A null
     defect_ref is well precedented here - RULE-AL, RULE-BDG, RULE-PDF and
     RULE-SUP all carry none. The three silent weeks that produced this rule
     are described in the body's closing paragraph. If that episode has a
     defect block, attach it with:
         UPDATE normalisation.rule_versions SET defect_ref = 'D-...'
         WHERE rule_id = 'RULE-STG' AND superseded_at IS NULL;

   CONSUMERS
     weekly-inbox-filing-review only. It is the one task producing staging
     batches today. Others are a one-row insert when they start:
         INSERT INTO normalisation.rule_consumers (rule_id, task_id, note)
         VALUES ('RULE-STG', '<task>', 'Added <date>.')
         ON CONFLICT (rule_id, task_id) DO NOTHING;
   ============================================================================ */

SELECT 'STEP 0 refuse to start unless the register is shaped as expected' AS check;

DO $preflight$
DECLARE
    v_missing   text;
    v_required  text;
    v_generated text;
    v_rule      integer;
    v_current   integer;
BEGIN
    IF to_regclass('normalisation.rules') IS NULL
       OR to_regclass('normalisation.rule_versions') IS NULL
       OR to_regclass('normalisation.rule_consumers') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: the normalisation rule register is not '
                        'present in this database. Nothing was changed.';
    END IF;

    /* A permission failure found halfway through is how a half registered
       rule happens, so find it before the first write. */
    IF NOT has_table_privilege('normalisation.rules', 'INSERT')
       OR NOT has_table_privilege('normalisation.rule_versions', 'INSERT')
       OR NOT has_table_privilege('normalisation.rule_versions', 'UPDATE')
       OR NOT has_table_privilege('normalisation.rule_consumers', 'INSERT') THEN
        RAISE EXCEPTION 'STEP 0 FAILED: % cannot write to the rule register. '
                        'Nothing was changed.', current_user;
    END IF;

    /* Every column this script names must exist, spelled as written. */
    SELECT string_agg(t.tbl || '.' || t.col, ', ' ORDER BY t.tbl, t.col)
      INTO v_missing
    FROM (VALUES
        ('rules',          'rule_id'),
        ('rules',          'title'),
        ('rules',          'scope_note'),
        ('rule_versions',  'rule_id'),
        ('rule_versions',  'version'),
        ('rule_versions',  'body'),
        ('rule_versions',  'change_reason'),
        ('rule_versions',  'effective_from'),
        ('rule_versions',  'superseded_at'),
        ('rule_versions',  'checksum'),
        ('rule_consumers', 'rule_id'),
        ('rule_consumers', 'task_id'),
        ('rule_consumers', 'note')
    ) AS t(tbl, col)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'normalisation'
          AND c.relname = t.tbl
          AND a.attname = t.col
          AND a.attnum > 0
          AND NOT a.attisdropped
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: column(s) this script relies on do not '
                        'exist: %. Nothing was changed.', v_missing;
    END IF;

    /* checksum must still be generated. If it were ever made an ordinary
       column, this script would silently leave every new rule version with a
       null checksum - so fail here instead. */
    SELECT a.attgenerated INTO v_generated
    FROM pg_attribute a
    JOIN pg_class c     ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'normalisation'
      AND c.relname = 'rule_versions'
      AND a.attname = 'checksum';
    IF v_generated <> 's' THEN
        RAISE EXCEPTION 'STEP 0 FAILED: rule_versions.checksum is no longer a '
                        'generated column, so this script would leave it null. '
                        'Add it to the insert. Nothing was changed.';
    END IF;

    /* And no column this script leaves unsupplied may be one the table
       insists on. This is the check that catches a register which has grown
       an owner, a category or a review date since these inserts were
       written - before any of them runs. */
    SELECT string_agg(c.relname || '.' || a.attname, ', ' ORDER BY c.relname, a.attname)
      INTO v_required
    FROM pg_attribute a
    JOIN pg_class c        ON c.oid = a.attrelid
    JOIN pg_namespace n    ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE n.nspname = 'normalisation'
      AND c.relname IN ('rules', 'rule_versions', 'rule_consumers')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.attnotnull
      AND d.adbin IS NULL
      AND a.attidentity = ''
      AND a.attgenerated = ''
      AND (c.relname || '.' || a.attname) NOT IN (
            'rules.rule_id',
            'rules.title',
            'rule_versions.rule_id',
            'rule_versions.version',
            'rule_versions.body',
            'rule_versions.effective_from',
            'rule_consumers.rule_id',
            'rule_consumers.task_id');
    IF v_required IS NOT NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: these column(s) are NOT NULL with no '
                        'default and this script supplies no value for them: '
                        '%. Add them to the inserts before running. Nothing '
                        'was changed.', v_required;
    END IF;

    SELECT count(*) INTO v_rule
    FROM normalisation.rules WHERE rule_id = 'RULE-STG';
    SELECT count(*) INTO v_current
    FROM normalisation.rule_versions
    WHERE rule_id = 'RULE-STG' AND superseded_at IS NULL;

    RAISE NOTICE 'STEP 0 OK: register shaped as expected, checksum still '
                 'generated. RULE-STG rule row(s) before this script: %, '
                 'current version(s): %', v_rule, v_current;
END
$preflight$;

SELECT 'STEP 1 the rule itself' AS check;

BEGIN;

INSERT INTO normalisation.rules (rule_id, title, scope_note)
VALUES ('RULE-STG',
        'Staging envelope contract',
        'Every record entering kws115 through the verifier app is carried by '
        'a staging envelope. Binds the producer, not the app: where batches '
        'go, the envelope keys, a derived record_uid, the manifest check, the '
        'registry as authority, field shapes, parents before children, and '
        'all-or-nothing batches.')
ON CONFLICT (rule_id) DO NOTHING;

COMMIT;

SELECT rule_id, title FROM normalisation.rules WHERE rule_id = 'RULE-STG';

SELECT 'STEP 2 the version, with the body' AS check;

BEGIN;

/* Supersede before inserting, in one transaction, because the partial unique
   index rule_versions_one_current allows exactly one row per rule with
   superseded_at IS NULL. The NOT EXISTS guard is what makes a second run a
   no-op rather than a supersede of this script's own row. */

UPDATE normalisation.rule_versions
SET superseded_at = CURRENT_DATE
WHERE rule_id = 'RULE-STG'
  AND superseded_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM normalisation.rule_versions
      WHERE rule_id = 'RULE-STG'
        AND change_reason = 'SCRIPT 2026-09-22: first version. Creates RULE-STG, the staging envelope contract for producers feeding the verifier app.'
  );

WITH new_body AS (
    SELECT $body$
Every record that enters kws115 through review is carried by a staging
envelope. This rule is the contract a producer must meet. It binds the
producer, not the app: the app refuses whatever does not meet it.

WHERE BATCHES GO. One file per record type per run, JSONL, into
  Finance and Data/Staging Inbox/
named  <task_id>__<record_type>__<UTC timestamp>.jsonl
with a sibling <same>.manifest.json. The ingester moves each file to
Processed/ on success and to Rejected/ with a .error.txt on failure.

NEVER CLEAR OR ARCHIVE THE SOURCE WORKBOOK. It is shared with processes
this contract does not own. Re-offering rows that were handled weeks ago
is expected and correct: what prevents double handling is record_uid,
not an empty file.

THE ENVELOPE. One JSON object per line, these keys, no others:

  schema_version  integer, currently 1
  record_uid      sha256(record_type + "|" + canonical_json(natural_key))
  batch_id        <task_id>__<record_type>__<UTC timestamp>
  record_type     must exist and be active in staging.record_type
  parent_uid      the parent's record_uid, or null for a root record
  seq             position within the parent, or null for a root record
  produced_by     the task_id that wrote it
  produced_at     ISO 8601 with offset
  natural_key     object; exactly the fields the registry declares
  payload         object; exactly the fields the registry declares
  provenance      object; source_document, source_workbook, party_name,
                  notes

RECORD_UID IS DERIVED, NEVER ASSIGNED. Canonical JSON means sorted keys
and no whitespace. Re-running a producer over unchanged input must
produce identical uids; that identity is the only thing standing between
a re-offered row and a duplicate. A producer that invents a uid, or
derives it from anything but the natural key, breaks the guarantee for
every feed.

THE MANIFEST carries row_count and sha256 of the .jsonl file exactly as
written. The ingester checks both before interpreting a single line,
because a truncated transfer otherwise looks exactly like a short batch.

THE REGISTRY IS AUTHORITATIVE. payload keys must match the record type's
field_spec exactly. A key the registry does not declare is not a bonus,
it is a rejected batch: register the field first, then produce it. A
declared field that is absent is null, and null in a required field is
also a rejected batch.

FIELD SHAPES, and the failures that wrote them:

  Money      amount_ex_gst, gst_amount, amount_inc_gst. Numbers, not
             strings, no currency symbol, no thousands separator.
  Dates      ISO YYYY-MM-DD. Not DD/MM/YYYY, which is a display format.
  Booleans   true or false, never 1/0 or "TRUE". A spreadsheet column
             holding blanks alongside TRUE arrives as a float, and 1.0
             compared as text is not "1": an in_invoice_total of TRUE
             was read as false for exactly that reason, inverting the
             meaning of the line and putting an invoice out by $6.65.
  Text       Identifiers that look numeric are STRINGS. An NMI, an
             account number and an invoice number are text in the
             destination, and handing over 20022924634 as a number
             fails at promotion with "operator does not exist: text =
             bigint", long after anyone is watching.
  Trim       Leading and trailing whitespace is stripped before the
             value is emitted. " 271069147" is not "271069147" to a
             duplicate guard or to a unique index, so an untrimmed cell
             is how a real duplicate reaches production.
  Enums      Exactly one of the values the registry lists, case and
             all. An enum whose value is merely plausible is refused.

ENUMS COME FROM THE DESTINATION. Where the target column carries a
CHECK constraint, the registry mirrors it, and the producer emits only
those values. Registering such a column as free text is how a typo
passes review and fails at write.

PARENTS BEFORE CHILDREN. A child carries its parent's record_uid and
its own seq, and its natural key includes that seq. Position is part of
identity because a document may legitimately repeat a line: several
identical linen items at one price on one invoice are several lines,
not one, and any key built from content alone silently drops them.

THE TWO NOTES ARE NOT THE SAME NOTE. provenance.notes is the producer's
reasoning - what the document printed, which rule governed a judgement,
what a later reconciliation should expect. payload.notes belongs to
whoever verifies, and a producer never writes it.

A BATCH IS ALL OR NOTHING. There is no partial load. A rejected batch
is fixed at the producer and re-emitted under a NEW file name: a
source_file that has already been ingested is never reused, because the
ingester will not overwrite a batch that landed.

NEVER WRITE TO kws115 DIRECTLY. Producers emit files. The app is the
only writer. See RULE-SQL for the script route where a genuine schema
or data change is needed.

WHY THIS RULE EXISTS. For three weeks nothing reached the cafe queue,
because a producer wrote "Inwards" where the app compared against
"Inward". Both were reasonable; neither was agreed. Nothing errored,
the file looked healthy, and the only symptom was a queue that stayed
quiet. A contract that lives in one system's head is not a contract,
and a mismatch that fails silently is worse than one that fails.
$body$::text AS body
)
INSERT INTO normalisation.rule_versions
    (rule_id, version, body, change_reason, effective_from)
SELECT 'RULE-STG',
       (SELECT coalesce(max(version), 0) + 1
          FROM normalisation.rule_versions
         WHERE rule_id = 'RULE-STG'),
       b.body,
       'SCRIPT 2026-09-22: first version. Creates RULE-STG, the staging envelope contract for producers feeding the verifier app.',
       CURRENT_DATE
FROM new_body b
WHERE NOT EXISTS (
    SELECT 1 FROM normalisation.rule_versions
    WHERE rule_id = 'RULE-STG'
      AND change_reason = 'SCRIPT 2026-09-22: first version. Creates RULE-STG, the staging envelope contract for producers feeding the verifier app.'
);

COMMIT;

SELECT version,
       to_char(effective_from, 'YYYY-MM-DD') AS effective_from,
       to_char(superseded_at, 'YYYY-MM-DD')  AS superseded_at,
       checksum,
       length(body) AS body_chars
FROM normalisation.rule_versions
WHERE rule_id = 'RULE-STG'
ORDER BY version;

SELECT 'STEP 3 the consumer' AS check;

BEGIN;

INSERT INTO normalisation.rule_consumers (rule_id, task_id, note)
VALUES ('RULE-STG',
        'weekly-inbox-filing-review',
        'Added 2026-09-22 with RULE-STG v1. Produces the staging batches this '
        'contract governs.')
ON CONFLICT (rule_id, task_id) DO NOTHING;

COMMIT;

SELECT task_id AS step3_consumers
FROM normalisation.rule_consumers
WHERE rule_id = 'RULE-STG'
ORDER BY task_id;

SELECT 'STEP 4 assertions for what this script left behind' AS check;

DO $verify$
DECLARE
    v_current   integer;
    v_version   integer;
    v_maxver    integer;
    v_checksum  text;
    v_body      text;
    v_from      date;
    v_reason    text;
    v_title     text;
    v_consumers integer;
    v_marker    text := 'SCRIPT 2026-09-22: first version. Creates RULE-STG, the staging envelope contract for producers feeding the verifier app.';
BEGIN
    SELECT title INTO v_title
    FROM normalisation.rules WHERE rule_id = 'RULE-STG';
    IF v_title IS DISTINCT FROM 'Staging envelope contract' THEN
        RAISE EXCEPTION 'ASSERT FAILED: RULE-STG is absent from '
                        'normalisation.rules, or its title is %', v_title;
    END IF;

    /* Exactly one current version, and it must be the one carrying this
       script's marker - not a pre-existing row that survived the supersede. */
    SELECT count(*) INTO v_current
    FROM normalisation.rule_versions
    WHERE rule_id = 'RULE-STG' AND superseded_at IS NULL;
    IF v_current <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: RULE-STG has % current version(s), '
                        'expected exactly 1', v_current;
    END IF;

    SELECT version, checksum, body, effective_from, change_reason
      INTO v_version, v_checksum, v_body, v_from, v_reason
    FROM normalisation.rule_versions
    WHERE rule_id = 'RULE-STG' AND superseded_at IS NULL;

    IF v_reason IS DISTINCT FROM v_marker THEN
        RAISE EXCEPTION 'ASSERT FAILED: the current RULE-STG version was not '
                        'written by this script. Its change_reason is %', v_reason;
    END IF;

    /* The version was derived, so it must be the highest on record. */
    SELECT max(version) INTO v_maxver
    FROM normalisation.rule_versions WHERE rule_id = 'RULE-STG';
    IF v_version <> v_maxver THEN
        RAISE EXCEPTION 'ASSERT FAILED: the current version is % but the '
                        'highest on record is %', v_version, v_maxver;
    END IF;

    IF v_checksum IS NULL OR v_checksum IS DISTINCT FROM md5(v_body) THEN
        RAISE EXCEPTION 'ASSERT FAILED: the generated checksum is null or does '
                        'not match md5(body)';
    END IF;

    IF v_from IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSERT FAILED: effective_from is % and not today', v_from;
    END IF;

    /* The body must be the approved one, not a truncated paste. Two cheap
       sentinels, one near each end: a body that lost its tail still passes a
       length check. */
    IF position('NEVER CLEAR OR ARCHIVE THE SOURCE WORKBOOK' in v_body) = 0
       OR position('a mismatch that fails silently is worse than one that fails' in v_body) = 0 THEN
        RAISE EXCEPTION 'ASSERT FAILED: the stored body is missing its opening '
                        'or its closing clause - it was truncated in transit';
    END IF;

    SELECT count(*) INTO v_consumers
    FROM normalisation.rule_consumers
    WHERE rule_id = 'RULE-STG' AND task_id = 'weekly-inbox-filing-review';
    IF v_consumers <> 1 THEN
        RAISE EXCEPTION 'ASSERT FAILED: weekly-inbox-filing-review is not '
                        'registered as a consumer of RULE-STG';
    END IF;

    RAISE NOTICE 'ASSERT OK: RULE-STG version % is current, effective %, '
                 '% characters, checksum %, 1 consumer registered',
                 v_version, to_char(v_from, 'YYYY-MM-DD'), length(v_body), v_checksum;
    RAISE NOTICE 'Compare that checksum with:  md5 -q db/RULE-STG-draft-body.txt';
END
$verify$;

SELECT 'STEP 5 migration 012 complete' AS check;
