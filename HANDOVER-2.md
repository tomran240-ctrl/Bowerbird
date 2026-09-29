# Bowerbird Verifier — handover 2 (session of 2026-09-29, later)

Read `HANDOVER.md` first: it is the base document (system, ground rules,
envelope, file inventory, database objects, traps). This document records what
changed since, what is verified and what is not, and what is waiting on Tom.
Where the two disagree, this one is newer.

Repo: `tomran240-ctrl/Bowerbird`. Working branch:
`claude/bowerbird-verifier-handover-i7t4ke` (contains everything below).
`verifier-app-import` is the raw import of Tom's Desktop folder and is already
merged into the working branch. Nothing has been merged to `main`; no PR has
been opened.

---

## 1. Ground rules that still bind (short form)

Full text in `HANDOVER.md` section 2. The ones that matter most here:

- The `kws115` connector is **read-only**. Every schema/data change is a
  plain-ASCII `.sql` script Tom runs himself (`psql kws115 -f db/0NN_..._commit.sql`).
- **RULE-SQL (v8) governs those scripts and must be fetched, not recalled.**
  It could not be fetched in this session (connector not attached), so
  migration 021 is a **DRAFT** (section 4).
- **RULE-RPT (v1) governs replies to Tom:** one status line, then numbered
  decisions each with a proposed answer, one line saying where the detail is,
  then stop. A closing `Unchanged since last run: ...` line, folded never omitted.
- Never print the database URL (`backend/.env.local`, not in the repo).
- Producers never write to `kws115`; the app is the only writer.
- The registry (`staging.record_type`) is the source of truth for field shape.
  Fix a registry row, not JavaScript, when a field is wrong.

Environment note: this Claude session is a cloud container. It has **no
database, no Desktop folders, no PDFs**. It can read and edit the repo only.
Nothing in this handover was run against `kws115`.

---

## 2. What was done this session

### 2.1 Repo
- `HANDOVER.md` committed (the original handover, verbatim).
- Tom pushed the verifier app from `~/Desktop/Finance and Data/Apps/verifier-app/`
  as branch `verifier-app-import` (`.env.local` was excluded by `.gitignore`;
  confirmed not in `git ls-files`). Merged into the working branch.
- Git auth for Tom's Mac push uses a GitHub fine-grained personal access token
  (contents read/write, this repo only) — not the account password.

### 2.2 Cross-check enforcement (HANDOVER.md section 8, gap 3 / section 9 item 5) — code done
`backend/main.py`: `_cross_check_status`, `_cross_check`, `_cross_check_blockers`,
`_refuse_on_cross_check`.
- For a Cafe `payroll_instruction`, each child line's `total_hours` is compared
  with Square **rostered** hours for the same `employee_code` and week
  (`period_end` = `pay_week_end`), tolerance from
  `validation.cross_check.tolerance_hours` (0.10 h = six minutes, inclusive).
- Rostered hours come from production `payroll.hours_line` (via
  `payroll.employee.square_team_member_id`) first, then from staged
  (`pending`/`verified`) `payroll_hours_line` records.
- Statuses mirror `payroll.v_pay_variance`: `OK`, `VARIANCE`,
  `NOT IN HOURS RUN`, `NO HOURS RUN`. Only `VARIANCE` blocks, and only when the
  registry mode is `block`.
- Verifying the instruction, one line, or all lines returns HTTP 422 with the
  people and variances named. Un-verifying is never blocked.
- UI (`backend/static/index.html`): `xcBanner`, red row highlight (`tr.xc-bad`),
  checkbox reverts on refusal.
- `GET /api/record/{uid}` now returns `cross_check`.

### 2.3 Reconcile enforcement — code done
`_reconcile` / `_reconcile_verdict` / `_reconcile_for` / `_refuse_on_reconcile`.
- `validation.reconcile` now supports any numeric child field (not only
  `line_total_inc_gst`): `payroll_instruction` sums `total_hours` against the
  header `total_hours`; `payroll_hours_run` sums `rostered_hours`.
- `against` is honoured (was hard-wired to `amount_inc_gst`).
- Default tolerance: `0.02` for `line_total_inc_gst`, **`0.05` for other sums**
  (seven lines rounded to 2 dp can drift ~0.035 h). A rule may set `tolerance`.
- A summed field missing on any line returns an error shown in the record view
  (never read as a total of zero — that would repeat the "column nothing
  populates" trap).
- `mode: block` refuses verifying the **parent** with HTTP 422; `warn` never refuses.
- Consequence to know: the three historical pay documents whose lines do not
  sum, and any instruction header that differs from its lines by more than
  0.05 h, will block at parent verification while the registry says `block`.
  To let them load, flip `payroll_instruction.validation.reconcile.mode` to
  `warn` by migration. Tom confirmed: keep `block`.

### 2.4 Cafe review changes — code done, SQL pending
Requested by Tom for Cafe invoices; status per item:

| # | Request | Status |
|---|---|---|
| 1 | View PDF | **Built.** Button on the record view, opens `/api/source-document/{name}` using `provenance.source_document`. Needs `VERIFIER_PDF_ROOTS` set (section 5). |
| 2 | Drop "GST Assessed" | **Built as hide, not delete** (see below). |
| 3 | Defect log field | **Built** (free text `defect_log` on `cafe_invoice`). Needs migration 021 first. |
| 4 | Bank debit matching | **NOT built.** Waiting on a sample statement (section 6). |
| 5 | Flag supplier not normalised | **Built.** |
| 6 | Import per invoice | **Built.** |

Details:

- **View PDF.** `main.py`: `PDF_ROOTS` (env `VERIFIER_PDF_ROOTS`, colon-separated,
  defaults to `VERIFIER_PDF_ROOT` = `INBOX TO FILE`), `_find_document(name)`
  (base name only, `.pdf` only, `rglob` under each root, cached),
  `GET /api/source-document/{name}`. `backend/staging_env.sh` gains
  `VERIFIER_PDF_ROOTS`. Filed invoices live in Desktop folders per RULE-FN, so
  INBOX TO FILE alone will usually not find them.
- **gst_assessed.** Kept in the registry as `hidden: true, editable: false,
  required: false` because the ingester rejects any payload key the registry
  does not declare (`validate_payload`), and the weekly task plus 22 pending
  lines still carry it. The UI skips hidden fields (record fields and child
  columns). `promote.py` PROMOTERS `cafe_invoice` has `child_exclude:
  {"gst_assessed"}`, applied identically in the plan preview and the write (the
  dry-run-must-equal-real-run trap). `cafe.purchases.gst_assessed` column is
  untouched. The reconcile line sum is now
  `line_total + coalesce(gst_declared, gst_assessed, 0)` (matches the legacy
  pattern at the old main.py line 121) so lines carrying only an assessed figure
  still reconcile. `PRODUCER-weekly-inbox-filing-review.md` updated: the
  producer may omit `gst_assessed`; `defect_log` optional.
- **Defect log.** Registry field `defect_log` (longtext, editable) on
  `cafe_invoice`; promoted automatically because `build_row` copies payload keys
  that are destination columns, so `cafe.invoices.defect_log` must exist
  **before** any invoice with a defect log is imported (otherwise
  `promote.py` only prints "dropped on promotion" and proceeds — a silent loss).
  Migration 021 adds the column.
- **Supplier not normalised.** `_party_normalised()`: only `match_type` in
  (`alias`,`exact`) with a `party_id` counts. A `fuzzy` match also carries a
  `party_id` (see `staging_ingest.py::match_party`), so it does not pass.
  Queue rows show a red `SUPPLIER NOT NORMALISED` badge; the record view shows a
  red banner naming the party, its match type and closest candidate.
  **`promote.py` now also blocks** any `needs_party` record (café invoices and
  `kw_invoice`, i.e. 115KW/117KW too) whose match is not alias/exact, on bulk
  promote as well as single import. Previously only a missing `party_id` blocked.
  Any already-`verified` record with a fuzzy match will now show as blocked.
- **Import per invoice.** `POST /api/record/{uid}/import` `{dry_run, by}` runs
  `promote.py --type T --only-uid UID [--dry-run]` as a subprocess (same code
  path and blocks as bulk promote; 300 s timeout). Only a `verified` parent, not
  a child. `promote.py` gained `--only-uid` and `candidates(..., only_uid)`.
  UI: "Import this invoice" button (disabled until verified; enabled when the
  Verified box is ticked), dry-runs first, shows the output, asks to confirm,
  then imports and returns to the queue.

### 2.5 Tests run (offline only)
Fake-cursor unit tests (kept in the session scratchpad, not the repo) covering
tolerance edges (exactly 0.10 h passes, 0.11 fails), blocker selection,
reconcile modes/tolerances/missing-field error, `_find_document` path safety,
`_party_normalised`. `py_compile` on `main.py`/`promote.py`; `node --check` on
the page script. **No SQL has been executed anywhere. The UI has not been
opened in a browser.** Treat all of section 2 as unverified against real data.

---

## 3. Commits on the working branch (newest last)

1. `HANDOVER.md`
2. Import of verifier app (Tom's `verifier-app-import`)
3. Enforce payroll_instruction cross_check
4. Merge of import + cross_check
5. Enforce validation.reconcile block mode for any summed child field
6. Cafe review: source PDF viewer, defect_log, gst_assessed retired, supplier-not-normalised flag, per-invoice import

Files touched: `backend/main.py`, `backend/promote.py`,
`backend/static/index.html`, `backend/staging_env.sh`,
`PRODUCER-weekly-inbox-filing-review.md`,
`db/021_cafe_defect_log_gst_retire_commit.sql` (new), this file.

---

## 4. Migration 021 — DRAFT, not yet run

`db/021_cafe_defect_log_gst_retire_commit.sql`, commit-only, three steps each in
its own transaction, idempotent, plus a pre-flight and an assertion block:

1. `ALTER TABLE cafe.invoices ADD COLUMN IF NOT EXISTS defect_log text`.
2. Append the `defect_log` field to the `cafe_invoice` registry spec (guarded
   with `NOT EXISTS`).
3. Mark `cafe_line.gst_assessed` `hidden:true, editable:false, required:false`
   (element rebuilt in place, order preserved; guarded on not already hidden).
4. Assertions: column exists; `defect_log` declared once; `gst_assessed` hidden
   and still declared exactly once.

It was written **without fetching RULE-SQL v8**. Before Tom runs it:
- fetch `RULE-SQL` and check the nine-point pre-flight and format rules;
- confirm ASCII only (checked: no non-ASCII), no backslash commands, block
  comments only (checked).
- It writes no rule versions, so the (rule_id, version) pre-flight point does
  not apply — the script says so.
- Trap reminders that apply: pre-flight from `pg_catalog`, not
  `information_schema`; explicit NULL overrides defaults (the new column is
  nullable with no default, so not exposed).

Tom said "yes" to a RULE-SQL check but has **not yet pasted the rule body**.

---

## 5. Things Tom must do (nothing here can be done from the cloud)

1. `git pull` the working branch into the Desktop app folder (or copy the changed
   files) so the running app has this code.
2. Set `VERIFIER_PDF_ROOTS` (colon-separated) in `backend/staging_env.sh` to the
   folder(s) café invoices are filed in. **Tom answered "yes" but did not give
   the path.**
3. Have RULE-SQL checked against migration 021, then run
   `psql kws115 -f db/021_cafe_defect_log_gst_retire_commit.sql`.
4. Restart the app with `./run.sh` and check, in this order:
   - a Cafe record shows **View PDF** and it opens;
   - `gst_assessed` no longer appears in line columns;
   - `defect_log` appears (after 021) on a café invoice;
   - an unnormalised supplier shows the red badge and banner;
   - **Import this invoice** dry-runs cleanly on a verified, normalised invoice;
   - open the Café `payroll_instruction` for `period_end` 2026-09-20 (60.25 h,
     8 lines) — the first live exercise of the six-minute tolerance.

Unverified SQL/assumptions that could break on first run (check these first if
something errors):
- `payroll.employee.square_team_member_id` — Tom confirmed it is text; the staged
  hours query joins it to `natural_key->>'square_team_member_id'`.
- Staged `payroll_hours_line` payloads carry `rostered_hours` (per migration
  018). If `018` was applied differently the staged half of the cross-check
  returns nothing (production half is unaffected).
- `staging.record.match_type` values: only `alias`/`exact`/`fuzzy`/`none` are
  known to exist.
- `cafe.purchases` may have triggers/defaults that compute `gst_assessed` on
  insert; if so, excluding it from the insert changes what production stores.
  Compare one imported line against a historical one.
- Legacy UI code (`renderInvoice`, the Tabulator grid with a `gst_assessed`
  column at roughly line 552 of `index.html`, and `/api/invoices*` endpoints) is
  still in the file. The Invoices Cafe tab is a registry queue since migration
  010, so this is believed dead but was not deleted or proven dead.

---

## 6. Outstanding work, in priority order

**Blocked on Tom**
1. Café PDF folder path (section 5.2).
2. RULE-SQL body, so migration 021 can be checked (section 4).
3. **Bank debit matching (request 4).** Agreed design (Tom said "yes" after
   "propose that it's staged"):
   - new registry record type `bank_debit`, staged like everything else, one
     record per debit line from the statement; natural key something like
     `{account, date, amount, description, seq}` (repeats are legitimate, so
     `seq` is part of identity);
   - each café invoice shows candidate debits (same amount, date within about
     +/-5 days of invoice/payment), and Tom picks one;
   - the chosen debit reference is stored on the invoice (a payload field, and a
     destination column on `cafe.invoices` via a further migration, e.g. `022`);
   - `bank_debit` needs a `target_schema`/`target_table` in the registry — decide
     whether debits are promoted to a `cafe` table or staged as match-only.
   - **Blocked on one sample bank statement/export** (CSV or PDF, account
     details blanked). A producer (`shim_bank_debits.py`, using
     `staging_envelope.py`/`stage_records.py`) cannot be written without the
     real columns. Do not guess the format.
4. **Payroll:** Tom will bring an instruction set "from another window". Nothing
   has been started. Ask him to paste it before assuming what it is.

**From HANDOVER.md section 9 (unchanged)**
- Verify and promote the Café `payroll_instruction` 2026-09-20 (settles the
  week-alignment question — see HANDOVER.md 9.1 and `RUN-2026-09-29.md` 9).
- Verify the 4 pending `cafe_invoice` (releases 14 verified `cafe_line`).
- Work the pending queue: 12 `kw_invoice`, 8 `payroll_instruction` + 35 lines,
  2 `cafe_invoice` + 8 lines.
- Backfill the remaining 44 payroll weeks; stage the 2026-09-21 week
  (`shim_payroll_hours.py --week 2026-09-21`).
- Housekeeping needing Tom's word: delete the legacy shim/ingest files, the
  eight `.bak-*` files, rewrite/delete the stale `README.md`.
- Review items: electricity charge tables lack a unique constraint; a child
  ingested after its parent is promoted is stranded silently; empty batch rows
  read confusingly in Batches.

**Never exercised (HANDOVER.md section 8), still true**
- The ingester's amend branch (a genuine payload amendment).
- The child NOT NULL pre-check refusing anything.
- **New this session and equally unexercised:** cross-check blocking, reconcile
  blocking, per-invoice import, PDF viewer, the supplier-normalisation block.

---

## 7. How to work with Tom

- Reply per RULE-RPT: status line, numbered decisions with a proposed answer
  each (he replies "1 yes, 2 no"), one line saying where detail is, then stop.
  Fold unchanged standing items into one `Unchanged since last run:` line.
- He answers tersely. "Yes" to a question that needed an input (a path, a file,
  a rule body) is **not** the input — ask again for the specific thing rather
  than proceeding on a guess. This happened three times in this session.
- Tom runs anything that writes to `kws115`. Give him a script and the command;
  never claim something is in the database until he says he ran it.
- Never print or ask him to paste the database URL or a token into chat.
- Do not open a PR unless he asks. Push only to the working branch.

## 8. Quick reference

```bash
# on Tom's Mac
cd ~/Desktop/Finance\ and\ Data/Apps/verifier-app/backend
set -a; . ./staging_env.sh; . ./.env.local; set +a
./run.sh                                   # http://127.0.0.1:8420
python3 promote.py --dry-run
python3 promote.py --type cafe_invoice --only-uid <record_uid> --dry-run
```

```sql
SELECT body FROM normalisation.v_rules_current WHERE rule_id = 'RULE-SQL';
SELECT record_type, row_status, count(*) FROM staging.record GROUP BY 1,2 ORDER BY 1,2;
SELECT match_type, count(*) FROM staging.record
WHERE record_type IN ('cafe_invoice','kw_invoice') GROUP BY 1;   -- who the new block affects
```
