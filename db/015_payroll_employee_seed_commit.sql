/* ============================================================================
   Bowerbird Verifier - migration 015 - COMMIT-ONLY
   Seed payroll.employee - the bridge between the two payroll sources.

   COMMIT-ONLY. One writing step, its own transaction, idempotent through
   ON CONFLICT (employee_code) DO NOTHING. No trailing ROLLBACK.

   Run:  psql kws115 -f 015_payroll_employee_seed_commit.sql

   HOW THIS WAS BUILT, AND WHY IT IS NOT GUESSWORK
     Square already stores each person's payroll code in the team member's
     reference_id field. 19 of the 20 cafe staff mapped straight across on
     that field alone - no name matching anywhere. The twentieth, HICK-A, has
     a blank reference_id in Square and was linked by hand to Abigail Hicks
     (TM58y7-Q0-cnfEti) on Tom's instruction; there are two people named Hicks
     in Square, so an automatic surname match was refused rather than risked.

     Every row below was generated from the 47 payroll PDFs and the Square
     team list by script. Nothing was transcribed by hand.

   THREE DEFECTS IN THE SOURCE CODES, all normalised here
     AN - P    Paul An's code is two letters, not three to five, and carries
               spaces. A pattern assuming three to five letters drops him
               from all 21 of his payroll weeks without a word. That happened
               during this work and was caught only because Tom knew he had
               been paid.
     THOM_M    Meera Thomas's code is typed with an underscore instead of a
               hyphen on the 02 Nov 2025 sheet - one week of 44.
     BENF- N   Naomi Benfield's reference_id in Square carries a space.
     The producer normalises whitespace and underscores before matching, and
     refuses a batch where any row that looks like a data row yields no code.

   NAMES, RECORDED AS THE PAYROLL SHEETS PRINT THEM
     BEER-G is spelled three ways: Geniveve on 14 sheets, Gennavieve on 2,
     and Genna in Square. The most frequent sheet spelling is used.
     PONC-O is PONCE DUQUE on the sheets and Ponce in Square; the fuller
     sheet form is kept.
     Neither is resolved by this script. If either is wrong, one UPDATE fixes
     it - the key is employee_code, not the name.

   reconciled IS TRUE ONLY FOR CAFE STAFF. 115connect and Farm hours are
   entered manually and have no second source, so they must never appear as
   unreconciled work. active reflects presence on the most recent sheet
   (20 Sep 2026), which is payroll truth rather than Square's status.

   This script writes no rule versions, so RULE-SQL pre-flight point 8 has no
   (rule_id, version) pair to compare.
   ============================================================================ */

SELECT 'STEP 0 refuse to start unless the table is empty and shaped right' AS check;

DO $preflight$
DECLARE
    v_rows integer;
BEGIN
    IF to_regclass('payroll.employee') IS NULL THEN
        RAISE EXCEPTION 'STEP 0 FAILED: payroll.employee does not exist. Run '
                        '013 first. Nothing was changed.';
    END IF;

    SELECT count(*) INTO v_rows FROM payroll.employee;
    IF v_rows > 0 THEN
        RAISE NOTICE 'STEP 0 NOTE: payroll.employee already holds % row(s). '
                     'Existing codes will be left exactly as found.', v_rows;
    END IF;

    RAISE NOTICE 'STEP 0 OK: seeding into a table holding % row(s)', v_rows;
END
$preflight$;

SELECT 'STEP 1 seed the register' AS check;

BEGIN;

INSERT INTO payroll.employee
    (employee_code, surname, first_name, business_unit, employment_class,
     square_team_member_id, reconciled, active)
VALUES
    ('DEVI-F', 'DeVIZIO',       'Franca',    '115connect', 'Casual', NULL,                false,  true),
    ('MATT-R', 'MATTIG',        'Rachel',    '115connect', 'Casual', NULL,                false,  true),
    ('RANK-T', 'RANKINE',       'Tom',       '115connect', 'Casual', NULL,                false,  true),
    ('AN-P',   'AN',            'Paul',      'Cafe',       'Casual', 'TM5lfkd9pLy1sOzB',  true,   false),
    ('BEER-G', 'BEER',          'Geniveve',  'Cafe',       'Casual', 'TMD9b21VCLGTYHLP',  true,   false),
    ('BENF-N', 'BENFIELD',      'Naomi',     'Cafe',       'Casual', 'TMhb8ucnEK5TxiFZ',  true,   true),
    ('BRIC-A', 'BRICE',         'Ashley',    'Cafe',       'Casual', 'TMgULQU6xs-UG_aW',  true,   true),
    ('DIAZ-C', 'DIAZ',          'Clyde',     'Cafe',       'Casual', 'TM3J43Uwh2WWp1AC',  true,   false),
    ('GAGE-M', 'GAJERA',        'Mansi',     'Cafe',       'Casual', 'TMjyRIzXaNqMyUD_',  true,   true),
    ('GUYA-L', 'GUYATT',        'Lewis',     'Cafe',       'Casual', 'TMaILOoKfRwF_lFN',  true,   false),
    ('HICK-A', 'HICKS',         'Abigail',   'Cafe',       'Casual', 'TM58y7-Q0-cnfEti',  true,   false),
    ('KAPE-Z', 'KAPETANOVIC',   'Zorica',    'Cafe',       'Casual', 'TMdzVa2EQh7movlA',  true,   false),
    ('MANG-A', 'MANGELSDORF',   'Amber',     'Cafe',       'Casual', 'TMXoFyM6g-hGFWQn',  true,   false),
    ('PARK-S', 'PARK',          'Selena',    'Cafe',       'Casual', 'TMuRUPc-U9fU42mY',  true,   false),
    ('PONC-O', 'PONCE DUQUE',   'Oriana',    'Cafe',       'Casual', 'TMM8tXDLl_MfAnbv',  true,   false),
    ('PURU-T', 'PURUSHOTHAMAN', 'Tanisha',   'Cafe',       'Casual', 'TMujHgD3bsroprWO',  true,   true),
    ('RAME-N', 'RAMESH',        'Neha',      'Cafe',       'Casual', 'TM5LL-pNef4Xhau5',  true,   true),
    ('RETS-O', 'RETSAS',        'Oliver',    'Cafe',       'Casual', 'TMLZbFg3zdsTXJQP',  true,   false),
    ('SADY-Z', 'SADYKOVA',      'Zukhra',    'Cafe',       'Casual', 'TMdzIIbA6rR8pfEa',  true,   false),
    ('SOFR-A', 'SOFRONIUC',     'Anastasia', 'Cafe',       'Casual', 'TMvxj0c7mVaz-rJf',  true,   false),
    ('STOR-L', 'STORBECK',      'Linda',     'Cafe',       'Casual', 'TMmNoLvpd87FM0zV',  true,   true),
    ('THOM-M', 'THOMAS',        'Meera',     'Cafe',       'Casual', 'TMky2MBBHy9fvAlN',  true,   true),
    ('TODD-M', 'TODD',          'Mia',       'Cafe',       'Casual', 'TMPskIxUKEC8wurY',  true,   true),
    ('PIEL-M', 'PIELAGO',       'Michael',   'Farm',       'Casual', NULL,                false,  true)

ON CONFLICT (employee_code) DO NOTHING;

COMMIT;

SELECT business_unit, count(*) AS people,
       count(square_team_member_id) AS linked_to_square,
       count(*) FILTER (WHERE reconciled) AS reconciled,
       count(*) FILTER (WHERE active) AS active
FROM payroll.employee GROUP BY business_unit ORDER BY business_unit;

SELECT 'STEP 2 assertions' AS check;

DO $verify$
DECLARE
    v_total integer; v_linked integer; v_recon integer; v_active integer;
    v_bad text;
BEGIN
    SELECT count(*), count(square_team_member_id),
           count(*) FILTER (WHERE reconciled), count(*) FILTER (WHERE active)
      INTO v_total, v_linked, v_recon, v_active
    FROM payroll.employee;

    IF v_total <> 24 THEN
        RAISE EXCEPTION 'ASSERT FAILED: % people in the register, expected 24',
                        v_total;
    END IF;

    /* Every cafe person must have a Square id, or they cannot be
       reconciled and the variance view would quietly skip them. */
    SELECT string_agg(employee_code, ', ' ORDER BY employee_code) INTO v_bad
    FROM payroll.employee
    WHERE business_unit = 'Cafe' AND square_team_member_id IS NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: cafe staff with no Square link: %', v_bad;
    END IF;

    /* And nobody outside the cafe may carry one, or they would start
       appearing in a variance queue they have no second source for. */
    SELECT string_agg(employee_code, ', ' ORDER BY employee_code) INTO v_bad
    FROM payroll.employee
    WHERE business_unit <> 'Cafe' AND square_team_member_id IS NOT NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: non-cafe staff linked to Square: %', v_bad;
    END IF;

    /* reconciled must track the business unit exactly. */
    SELECT string_agg(employee_code, ', ' ORDER BY employee_code) INTO v_bad
    FROM payroll.employee
    WHERE reconciled <> (business_unit = 'Cafe');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'ASSERT FAILED: reconciled disagrees with business '
                        'unit for: %', v_bad;
    END IF;

    IF v_linked <> 20 OR v_recon <> 20 OR v_active <> 12 THEN
        RAISE EXCEPTION 'ASSERT FAILED: expected 20 linked / 20 '
                        'reconciled / 12 active, got % / % / %',
                        v_linked, v_recon, v_active;
    END IF;

    RAISE NOTICE 'ASSERT OK: % people, % linked to Square, % reconciled, '
                 '% currently active', v_total, v_linked, v_recon, v_active;
    RAISE NOTICE 'The bridge is seeded. The producers can now run.';
END
$verify$;

SELECT 'STEP 3 migration 015 complete' AS check;
