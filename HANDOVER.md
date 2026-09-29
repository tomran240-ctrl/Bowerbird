# Bowerbird Verifier — handover

**As at 2026-09-29 (revised after that morning's ingest).** Written for Claude Code picking this up cold. Everything
below was checked against the live database and the disk on the day, not
recalled. Where a figure will age, the query that produced it is given so you
can re-check rather than trust it.

---

## 1. What this system is

Documents arrive from several sources — café supplier invoices, building
invoices, electricity bills, payroll instructions, Square hours runs. Each
source used to reach the `kws115` database by its own route: a workbook here, a
hand-run SQL script there, a direct insert somewhere else. The goal of this work
was **one uniform format** for anything on its way in, so that whatever the
source, a record is:

```
produced  ->  staged  ->  reviewed in the verifier app  ->  promoted into kws115
```

That format is the **staging envelope**, and the contract for it is RULE-STG
(currently v2), registered in the database. The verifier app is a FastAPI
backend plus a single-page UI; its grid, editors, enums and validation are all
driven from a registry table, so adding a record type is a data change, not a
code change.

The cutover is complete for the café/building/payroll feeds: the weekly
`weekly-inbox-filing-review` scheduled task is now the producer and writes
envelope files itself.

---

## 2. Ground rules — read before touching anything

These are not style preferences. Each one is here because breaking it has cost
real time.

**2.1 The `kws115` MCP connector is read-only.** You can query it freely. You
cannot write through it. Every schema or data change is delivered as a
plain-ASCII `.sql` script that Tom runs himself:

```
psql kws115 -f db/0NN_name_commit.sql
```

**2.2 `RULE-SQL` (v8) governs every one of those scripts.** Do not write one
from memory of this document. Fetch it first:

```sql
SELECT body FROM normalisation.v_rules_current WHERE rule_id = 'RULE-SQL';
```

Its shape, in brief, so you know what you are fetching: plain ASCII only, no
`psql` backslash commands, block comments only, per-step row counts, assertion
`DO` blocks that `RAISE EXCEPTION` on failure, rule versions **derived** never
literal, business keys never surrogate ids, a nine-point mechanical pre-flight,
and a script that is **either** a dry run (one transaction, `ROLLBACK` at the
end) **or** commit-only (separately committed idempotent steps). Never both.

**2.3 `RULE-STG` (v2) governs every staging file.** Fetch it the same way. It
defines the envelope, the `record_uid` derivation, and amendment semantics.

**2.4 `RULE-RPT` (v1) governs how you report to Tom.** Two layers. Layer 1
DECISIONS: one status line, then one numbered line per item that needs him, each
carrying a proposed answer so he can reply "1 yes, 2 no". Layer 2 DETAIL:
everything else, in the run file, not in chat. Chat replies are status line,
numbered decisions, one line saying where the detail is, then stop. No recap, no
restating the request, no narrating steps. Standing items unchanged since last
run fold into one closing `Unchanged since last run: ...` line — folded, never
omitted.

**2.5 Never print the database URL.** It lives in `backend/.env.local`, mode
600, and carries a password. `run.sh` sources it. Do not echo it, do not paste it
into a script, do not include it in output.

**2.6 Producers never write to `kws115`.** A producer writes envelope files into
the Staging Inbox and stops. The app is the only writer. This is what makes the
review step meaningful.

**2.7 Never clear or archive a source workbook.** RULE-STG is explicit. The one
exception, granted by Tom once the shim became their sole reader, is the two
*invoice* workbooks.

**2.8 The registry is the source of truth for field shape.** `staging.record_type`
drives the grid, the editors, the enums, the validation and the reconciliation.
If the UI is wrong about a field, fix the registry row, not the JavaScript.

---

## 3. Where things live

| What | Path |
|---|---|
| App | `~/Desktop/Finance and Data/Apps/verifier-app/` |
| Staging Inbox | `~/Desktop/Finance and Data/Staging Inbox/` |
| — ingested | `.../Staging Inbox/Processed/` |
| — refused | `.../Staging Inbox/Rejected/` |
| Payroll PDFs | `~/Desktop/Finance and Data/Payroll/` |
| Square ledger | `~/Desktop/Finance and Data/Payroll/Payroll_Outputs/payroll_ledger.jsonl` |
| Inbox to file | `~/Desktop/INBOX TO FILE/` |
| Producer instruction | `verifier-app/PRODUCER-weekly-inbox-filing-review.md` |
| Run notes | `verifier-app/RUN-2026-09-29.md` |

Paths are defined once in `backend/staging_env.sh`, which `run.sh` sources. To
run a CLI tool by hand:

```bash
cd ~/Desktop/Finance\ and\ Data/Apps/verifier-app/backend
set -a; . ./staging_env.sh; . ./.env.local; set +a
```

Start the app:

```bash
cd ~/Desktop/Finance\ and\ Data/Apps/verifier-app/backend && ./run.sh
# then http://127.0.0.1:8420
```

`run.sh` exists because a bare `uvicorn` line once brought the app up against
`kws115_TEST` with auto-ingest off, silently. It prints the database, the paths,
and warns on the test database.

**Note:** `README.md` at the app root is stale — it describes the first build,
against an imagined pipeline, and its file list is out of date. This document
supersedes it. Do not follow the README's migration instructions.

---

## 4. The staging envelope

Eleven keys, every record, every type:

```json
{
  "schema_version": 1,
  "record_uid": "<sha256 hex>",
  "batch_id": "<produced_by>__<record_type>__<YYYYMMDDTHHMMSSZ>",
  "record_type": "cafe_invoice",
  "parent_uid": null,
  "seq": null,
  "produced_by": "weekly-inbox-filing-review",
  "produced_at": "<ISO8601 UTC>",
  "natural_key": { },
  "payload": { },
  "provenance": {
    "source_document": "...",
    "source_workbook": null,
    "party_name": "...",
    "notes": "..."
  }
}
```

`provenance` carries **exactly** those four keys — no more, no fewer.

### 4.1 `record_uid` is the whole dedup mechanism

```
record_uid = sha256(record_type + "|" + canonical_json(natural_key))
```

Canonical means **sorted keys, no whitespace** — in Python,
`json.dumps(obj, sort_keys=True, separators=(",", ":"))`. One byte wrong and the
guarantee is gone *silently*, because a wrong uid looks exactly like a new
record. This is why there is one definition of it, in
`backend/staging_envelope.py`, and why producers are given
`stage_records.py` rather than being asked to compute hashes themselves.

A child's `natural_key` **contains its `seq`**. Position is part of identity,
because a document may legitimately repeat a line, and a key built from content
alone drops the repeats.

### 4.2 Amendment semantics (RULE-STG v2)

`record_uid` identifies a record, **not a version of it**. Re-offering a record
with a changed payload is an *amendment*, not a duplicate:

- unchanged payload, any status → counted `unchanged`, nothing written
- changed payload, record still `pending` → the pending row is **updated**
- changed payload, record already `verified` / `imported` / `deleted` → the
  **whole batch is refused**, with the conflict listed

This was added after a real failure: corrections re-staged in hours were
swallowed by `ON CONFLICT DO NOTHING`, counted as 16 duplicates, and the batch
marked ingested. Nothing was wrong on screen. The ingest summary now reads
`N records loaded, N unchanged, N amended`.

---

## 5. File inventory

### `backend/` — the envelope and the pipeline

| File | Owns |
|---|---|
| `staging_envelope.py` | **The contract, in one place.** `SCHEMA_VERSION`, `PROVENANCE`/`PRODUCED_BY`, `canonical()`, `record_uid()`, `envelope()`, `batch_id_for()`, `write_batch()`. Stdlib only — no pandas, deliberately, so any producer can import it. |
| `stage_records.py` | **The producer's entry point.** Takes a JSON file of `natural_key` / `payload` / `provenance` and writes compliant batches. Computes `record_uid` and `parent_uid` so a producer never does: a child names its parent's *natural key*, so parent and child cannot disagree about what they are linked to. Refuses the whole file on structural faults (missing keys, wrong provenance key set, child `seq` disagreeing with `natural_key.seq`, duplicate natural key in a batch, unresolvable parent, NaN/Infinity). Does **not** read the registry or the database — that check belongs to the ingester, and two checks of the same thing in two places drift apart. |
| `staging_ingest.py` | **The one way records enter staging.** Watches the inbox, validates each batch against the registry, loads it all-or-nothing into `staging.batch` + `staging.record`, moves the file to `Processed/` or to `Rejected/` with a reason on disk. Holds `classify_existing()` — the amendment logic — which joins via `unnest(%s::text[], %s::jsonb[])` so the database does the payload comparison, not Python. |
| `promote.py` | **Verified staging rows into production.** `--dry-run` / `--type X` / bare. Per-type extras functions (`cafe_extras`, `payroll_instruction_extras`, `payroll_hours_run_extras`, …), `_mins()` for the hours→minutes conversion, a child NOT NULL pre-check at plan time, and `child_extras_each` so per-child values are computed per child rather than once from the parent. `table_columns()` excludes generated and identity columns — they cannot be inserted into. |
| `staging_reconcile.py` | Finds staged records whose production row already exists; `--apply` marks them imported. |
| `staging_remove_batch.py` | Takes a staged batch back out. `--list`, `--batch X --dry-run`, `--batch X`. |
| `shim_invoice_staging.py` | **Retired as a producer.** Now only re-exports the envelope helpers for backwards compatibility; its workbook-reading half was removed by AST line range. The task writes envelopes directly. Safe to delete once the task's output is trusted. |
| `shim_electricity_staging.py` | Still the producer for the three electricity workbooks. |
| `shim_payroll_instruction.py` | Reads the 47 pay-instruction PDFs with `pdftotext -layout`. Section map handles both vocabularies (`Admin - Building Management` → 115connect, `Gardener` → Farm) and **rejects unknown headings**. `period_end` read from the body and asserted equal to the filename date. Column anchors per document with nearest-anchor numeric assignment. A completeness check — this is what caught two employee codes the pattern missed. |
| `shim_payroll_hours.py` | Reads `payroll_ledger.jsonl`, emits decimal hours, maps the ledger's `payable_minutes` → `clocked_hours`. Re-asserts the identities in minutes before emitting; a bad row is skipped and reported while the rest still stages. |
| `workbook_values.py` | `clean`, `as_text`, `to_bool` — spreadsheet cells into JSON-safe values. Needs pandas, which is why it is not in `staging_envelope.py`. |
| `main.py` | FastAPI app, 26 endpoints, serves `static/`. `/api/ingest-run`, `/api/promote`, `/api/queue/{tab_key}`, `/api/record/{record_uid}` and friends. |
| `staging_env.sh`, `run.sh` | Paths and launcher. |
| `ingest_lib.py`, `ingest_invoice_summary.py`, `ingest_cafe_line_items.py` | **Legacy.** Pre-registry, pre-envelope. Not on any live path. Deletable with the shim. |

### `db/` — migrations, all applied

`001`–`003` original schema · `005` staging envelope · `006` nav tabs ·
`007` tab sources · `008` registry corrections · `009` promotion grants ·
`010` café cutover · `011` clear already-imported café · `012` register
RULE-STG · `013` payroll schema · `014` payroll tab sources · `015` payroll
employee seed (24 people) · `016` line-sum warning not block · `017` rebuild
`v_pay_variance` · `018` hours columns · `019` RULE-STG v2 · `020` registry
enums derived from destination CHECK constraints.

`db/RULE-STG-draft-body.txt` is the rule body and the source of truth for `012`
and `019` — the registered body was verified byte-identical to it (md5
`5a447ce2e095b82ba65b3132a5cb9156`, 6671 bytes). If you revise the rule, revise
this file and generate the migration from it; do not retype the body into SQL.

---

## 6. Database objects

**`staging`** — `record_type` (the registry: `field_spec` and `validation`
jsonb), `record`, `record_edit`, `batch`, `nav_tab`, `nav_tab_source`,
`v_enum_from_destination`, plus the legacy `cafe_invoices` / `cafe_purchases`
staging tables.

**13 registered record types**, all active:

```
cafe_invoice            -> cafe.invoices                                (parent)
  cafe_line             -> cafe.purchases
kw_invoice              -> accounting.invoices                          (parent)
elec_main_bill          -> accounting.main_meter_bills                  (parent)
  elec_main_charge      -> accounting.main_meter_bill_charges
  elec_main_other_charge-> accounting.main_meter_bill_other_charges
elec_ind_bill           -> accounting.individual_meter_bills            (parent)
  elec_ind_charge       -> accounting.individual_meter_bill_charges
  elec_ind_other_charge -> accounting.individual_meter_bill_other_charges
payroll_instruction     -> payroll.pay_instruction                      (parent)
  payroll_instruction_line -> payroll.pay_instruction_line
payroll_hours_run       -> payroll.hours_run                            (parent)
  payroll_hours_line    -> payroll.hours_line
```

**8 nav tabs:** Forms · Invoices 115KW (`kw_invoice`, `elec_main_bill`,
`elec_ind_bill`) · Invoices 117KW (`kw_invoice`) · Invoices Cafe
(`cafe_invoice`) · Payroll (`payroll_instruction`, `payroll_hours_run`) ·
Reconciliation · Batches · Import history.

**`payroll`** — `employee` (24 rows; `square_team_member_id` is the bridge
between the two payroll sources), `pay_instruction`, `pay_instruction_line`,
`hours_run`, `hours_line`, and the view `v_pay_variance`.

### 6.1 Two things about payroll that are easy to get wrong

**Café staff are paid their ROSTERED hours.** The time clock verifies attendance
and never adjusts pay. So the figure that matters is `rostered_*`; the clock
variances travel alongside as information. Tolerance is six minutes (0.10 h),
held in the registry at
`staging.record_type.validation -> 'cross_check' -> 'tolerance_hours'` and read
from there by the view, so there is one source of truth for it.

**Minutes are canonical, hours are the presentation.** The Square ledger is
integer minutes. `clocked = rostered + adj_a + adj_b` is exact in minutes and is
*not* exact in hours rounded to 2 dp — the 20 September run breaks the identity
that way. The database stores minutes; the `*_hours` columns are
`GENERATED ALWAYS AS ... STORED`. Going hours → minutes via `round(h*60)` is
provably exact (error ≤ 0.3 min < 0.5), which is what lets `promote.py::_mins()`
reconstruct them, and a CHECK on the table verifies it rather than trusting it.

Generated columns cannot be inserted into. `promote.py::table_columns()` filters
them with `AND a.attgenerated = '' AND a.attidentity = ''`.

---

## 7. Current state, 2026-09-29

### Staging queue

```sql
SELECT record_type, row_status, count(*) FROM staging.record GROUP BY 1,2 ORDER BY 1,2;
```

| Type | pending | verified | imported | deleted |
|---|---|---|---|---|
| `cafe_invoice` | 4 | — | 14 | — |
| `cafe_line` | 22 | 14 | 69 | — |
| `kw_invoice` | 16 | — | 2 | 1 |
| `payroll_instruction` | 8 | — | 1 | — |
| `payroll_instruction_line` | 35 | — | 1 | — |
| `payroll_hours_run` | 2 | — | — | — |
| `payroll_hours_line` | 14 | — | — | — |

**51 records are `verified` and not yet promoted** (7 café invoices + 44 lines).
`promote.py` will take them.

### Production

`cafe.invoices` 335 · `cafe.purchases` 4057 — 7 invoices and 30 lines were
promoted on 29 September, every one reconciling exactly ex-GST, and `notes`
carried through from provenance on all seven.

`payroll.employee` 24 · `pay_instruction` 1 · `pay_instruction_line` 1 ·
`hours_run` 3 · `hours_line` 20 · `v_pay_variance` **20 rows**.

All 20 variance rows read `WORKED, NOT PAID`, which is the expected reading and
not an alarm: the Square side of three weeks is in production and the
instruction side is not. The only promoted instruction is Farm. Every row
resolves an `employee_code`, so the bridge works and simply has nothing to
compare against yet. The six-minute tolerance has still never been applied.

14 `cafe_line` remain `verified` and unpromoted: their parents are still
`pending`, so they wait for the parent to be verified. That is correct
behaviour, not a stranding — `candidates()` plans from parents only.

The empty view is not a fault. The single promoted instruction is
`business_unit = 'Farm'`, week ending 2026-09-05, 38.00 h, and the view filters
to `'Cafe'`. It will populate when a café instruction and its matching hours run
are both promoted — which is also the test that has not been run.

### The inbox is clear

Four batch files had been waiting since the 24th. They were ingested on
2026-09-29 at 00:24 — 20 of 20 rows landed, nothing rejected:

| Batch | Rows |
|---|---|
| `...__kw_invoice__20260924T223403Z` | 1 |
| `...__cafe_invoice__20260928T225452Z` | 2 |
| `...__cafe_line__20260928T225452Z` | 14 |
| `...__kw_invoice__20260928T225452Z` | 3 |

That is the producer cutover proved end to end: the task wrote the envelopes
unaided on the 24th and the 28th, and every record validated against the
registry first time. `backend/_tmp_staging_batch_20260928.json` is the task's
own input file from the 28th, left behind; it is scratch and can go.

### The Friday payroll run did fire

`payroll_ledger.jsonl` holds three weeks:

| Week | Run date | Staff |
|---|---|---|
| 2026-09-07 → 09-13 | 11 Sep | 7 |
| 2026-09-14 → 09-20 | 18 Sep | 7 |
| **2026-09-21 → 09-27** | **25 Sep** | **6** |

The 25 September week is in the ledger and **not staged** — staging holds only
the first two runs. `shim_payroll_hours.py --week 2026-09-21` collects it.

---

## 8. Code paths that have never been exercised

Say so before relying on any of these. Hours-run promotion **was** on this
list and came off it on 29 September: 3 runs and 20 lines promoted, minutes
matching the ledger exactly, no `*_hours` column disagreeing with its minutes,
every line reaching an employee, and all three CHECK constraints exercised.
`RUN-2026-09-29.md` §9 has the figures.

1. **The ingester's amend branch.** `classify_existing()` reported
   `0 amended` across 100 re-offered records in the drain run, which proves the
   *unchanged* path. A genuine payload amendment has not been put through it.
2. **The child NOT NULL pre-check** in `promote.py`'s plan phase has not
   refused anything yet. A sibling gap beside it *was* found on 29 September and
   fixed: the pre-check correctly ignores NOT NULL columns that have a default,
   but `build_row` went on to write an explicit null into one, which overrides
   the default. See §10. The preview and the write now build rows the same way,
   which is the property whose absence caused it.
3. **`validation.cross_check` is not read by the app.** A variance beyond six
   minutes shows in `v_pay_variance` but does not block the row in the grid.
   This is the last functional gap in the payroll feed.

---

## 9. Outstanding work

**Immediate**

1. Verify and promote the **Café** `payroll_instruction` for `period_end`
   2026-09-20 (60.25 h, 8 lines). Its total already equals its own week's Square
   rostered total, so this is the first real exercise of the six-minute
   tolerance, and it settles an open question: the 2026-09-06 instruction's
   57.50 h also equals the 2026-09-13 run's rostered total one week later, while
   2026-09-13's 54.50 h matches nothing. Either `period_end` means the end of
   the week worked and that is a coincidence, or the alignment is off by a week.
   `RUN-2026-09-29.md` §9 sets it out.
2. Verify the 4 pending `cafe_invoice` in the app, which releases the 14
   verified `cafe_line` waiting on them.

**Then**

5. Make the app read `validation.cross_check` so a beyond-tolerance variance
   blocks in the grid (§8.4).
6. Work the pending queue: 12 `kw_invoice`, 8 `payroll_instruction` + 35 lines,
   2 `cafe_invoice` + 8 lines.
7. Backfill the remaining 44 payroll weeks.

**Housekeeping, needs Tom's word**

8. Delete `shim_invoice_staging.py`, `ingest_invoice_summary.py`,
   `ingest_cafe_line_items.py`, `ingest_lib.py` once the task's output is
   trusted. An optional guard flag on the shim was offered and not answered.
9. Eight `.bak-*` files in `backend/` awaiting permission to delete.
10. Rewrite or delete the stale `README.md`.

**Known review items, not yet addressed**

11. The electricity charge tables have no unique constraint.
12. A child ingested after its parent is promoted is stranded silently.
13. Empty batch rows read confusingly in the Batches page.

---

## 10. Traps already paid for

Each of these cost time once. They are listed so they cost nothing twice.

- **`rule_versions.checksum` is `GENERATED ALWAYS AS (md5(body)) STORED`.**
  Writing it fails. Pre-flight `pg_catalog`, not `information_schema` — the
  latter is privilege-filtered and will hide a column you need to see.
- **`rules.title` is NOT NULL.** A `rule_id`-only insert fails.
- **An explicit `NULL` overrides a column default.** It does not fall back to
  it. This has now cost time twice, from both directions.
  `staging.nav_tab_source.filter` is `NOT NULL DEFAULT '{}'::jsonb`, and
  migration 013 passing `filter = NULL` failed; then on 29 September a
  promotion aborted on `cafe.purchases.in_invoice_total`
  (`boolean NOT NULL DEFAULT true`) because five payloads carried
  `in_invoice_total: null` and `build_row` copied the key through. Pre-flight
  the nullability of the columns you are **supplying**, not only the ones you
  are omitting — and in code, omit the key rather than writing the null.
  `promote.py::defaulted_not_null()` is the mirror of `required_columns()` and
  exists for this; `build_row(..., omit_if_none=)` applies it. Only one column
  in the whole registry is exposed this way, and the query that proves it is in
  `RUN-2026-09-29.md` §6.
- **A dry run that builds a different row from the real run is not a dry run.**
  The abort above was reported as `no blocks found` thirty seconds earlier,
  because the preview and the write called `build_row` with different
  arguments. Whatever the plan phase computes, the write phase must use.
- **A CHECK constraint encodes what the *system* guarantees, never what a human
  document is expected to honour.** Three pay instruction documents do not sum;
  a CHECK would have rejected them. This mistake was made twice in one build —
  also with a Sunday `period_end` constraint. Such things are warnings, not
  blocks. Migration `016` exists to undo one of them.
- **A join on a column nothing populates fails silently and looks like an empty
  queue.** `v_pay_variance` originally joined `hours_line.employee_code`, which
  is not in the field spec and would have been NULL forever, reporting
  `NO HOURS RUN` for everyone permanently. Migration `017` rebuilt it on the
  Square id bridge and dropped the column, because a null foreign key *invites*
  that join.
- **`DROP VIEW` discards its grants.** Re-`GRANT` in the same script, and assert
  the grant exists afterwards.
- **A one-directional view cannot see the more serious error.** `v_pay_variance`
  is a FULL OUTER JOIN so that "worked, not paid" is visible, not only "paid,
  not worked".
- **`device_commit_files` can send a pre-edit copy.** It happened twice. md5 the
  file after every copy and retry until it matches; a retry always resolved it.
  A structural lint passes happily on a file missing the line you just added.
- **A parser that matches a subset is worse than one that matches nothing.** A
  code pattern requiring 3–5 letters before the hyphen missed `AN - P` and
  reported 407 hours as unpaid; Tom knew the person had been paid. The fix was
  not a better pattern, it was a **completeness check** — which then found
  `THOM_M` too.
- **Validate the thing that can be wrong, not something adjacent to it.** Every
  silent failure in this build came from checking a neighbour: structure instead
  of content, a sampled row instead of the mechanism, a value the record already
  held.
- **Two producers of the same records amend each other every Refresh.** When
  cutting a feed over, the old producer stops *before* the new one starts, not a
  week later.

---

## 11. Quick reference

```bash
# environment
cd ~/Desktop/Finance\ and\ Data/Apps/verifier-app/backend
set -a; . ./staging_env.sh; . ./.env.local; set +a

# run the app
./run.sh                                   # http://127.0.0.1:8420

# ingest whatever is in the inbox
python3 staging_ingest.py

# promote
python3 promote.py --dry-run
python3 promote.py --type cafe_invoice
python3 promote.py

# producers
python3 stage_records.py --in records.json --dry-run
python3 shim_payroll_hours.py --week 2026-09-21 --dry-run
python3 shim_payroll_instruction.py --dry-run
python3 shim_electricity_staging.py --dry-run

# take a batch back out
python3 staging_remove_batch.py --list
python3 staging_remove_batch.py --batch <batch_id> --dry-run

# reconcile staging against production
python3 staging_reconcile.py
```

```sql
-- the rules that govern this work
SELECT rule_id, version, title FROM normalisation.v_rules_current
WHERE rule_id IN ('RULE-SQL','RULE-STG','RULE-RPT','RULE-PAY','RULE-CS','RULE-AMT');

-- state of the queue
SELECT record_type, row_status, count(*) FROM staging.record GROUP BY 1,2 ORDER BY 1,2;

-- batches and what landed
SELECT batch_id, record_type, status, declared_rows, ingested_rows, produced_at
FROM staging.batch ORDER BY produced_at DESC LIMIT 20;

-- registry drift against destination CHECK constraints
SELECT * FROM staging.v_enum_from_destination WHERE registry_values IS DISTINCT FROM destination_values;
```

---

## 12. Decisions and findings of 29 September, later session

This section records what was settled after `HANDOVER-2.md` was written. Read
that document for the code it describes; this is what the database and the disk
say about it. Where the two disagree on a fact about production, this is newer.

### 12.1 `gst_assessed` keeps being written to production — already true, no change needed

`promote.py` on the working branch carries **no** `child_exclude` value for
`cafe_invoice`. The `child_exclude` machinery exists and mirrors the parent
`exclude`, but no record type uses it, so `gst_assessed` is written as it always
was. Migration 021's own header says the same in as many words: *"It is still
written to `cafe.purchases.gst_assessed` on promotion, because that column holds
the only GST on many lines."*

`HANDOVER-2.md` section 2.4 describes an exclusion that the code does not
contain — it was written before that decision was reversed and never caught up.
**Nothing needs changing in `promote.py`.** The figures below are why it must
stay that way, and are worth keeping even though the danger passed.

`cafe.purchases.gst_assessed` is the column that holds café line GST:

| Cohort | rows | with `gst_declared` | with `gst_assessed` | assessed non-zero and declared null |
|---|---|---|---|---|
| historical | 4027 | 387 | 3423 | **1744** |
| promoted 29 Sep | 30 | 10 | 30 | **14** |

It is nullable, has no default, and `cafe.purchases` has no triggers, so leaving
it out of the INSERT writes NULL. For 1744 historical rows and 14 of the 30
promoted on 29 September it is the only GST on the line. Excluding it would not
retire a column, it would stop recording café GST.

"Drop the GST Assessed field" is satisfied by the registry's `hidden: true`,
which removes it from the grid and the editors. Keep that; drop the exclusion.

A second reason: the reconcile sum was changed to
`line_total + coalesce(gst_declared, gst_assessed, 0)`, so the code already
trusts the figure to check an invoice total against. Trusting it to reconcile and
refusing to store it cannot both be right.

### 12.2 The supplier-normalisation block ships as built — decided

No verified or imported record is affected. All 18 `cafe_invoice` records are
`alias`. Among `kw_invoice`: 13 `exact`, 2 `alias`, 1 `fuzzy` (pending), 3 `none`
(already blocked on a missing `party_id`). `match_type` holds only those four
values. The rule newly blocks exactly one pending record.

### 12.3 `VERIFIER_PDF_ROOTS` — settled, and no filing fault

Of 18 staged or imported café invoices, 7 have their `provenance.source_document`
under `Invoice Inwards - Cafe`; the other 11, all dated 21–28 September, are in
`~/Desktop/INBOX TO FILE` at the top level, unfiled. **All 11 accounted for** —
the producer is not staging records for documents it has not got, it is staging
ahead of the filing step, which is the intended order.

`INBOX TO FILE` holds 304 PDFs, so the unfiled backlog is substantial and the
inbox must stay in the search path permanently, not as a fallback.

```
VERIFIER_PDF_ROOTS="/Users/admin/Desktop/INBOX TO FILE:\
/Users/admin/Desktop/Finance and Data/Invoice Inwards - Cafe:\
/Users/admin/Desktop/Finance and Data/Invoice Inwards - 115KW:\
/Users/admin/Desktop/Finance and Data/Invoice Inwards - 117KW:\
/Users/admin/Desktop/Finance and Data/Invoice Inwards - 115KW Electricity:\
/Users/admin/Desktop/Finance and Data/Invoice Inwards - 117KW Electricity:\
/Users/admin/Desktop/Finance and Data/Accountant Batch - Cafe - July 2026"
```

Inbox first, because a freshly staged invoice is the one most likely to be
opened. `_find_document` uses `rglob`, so month subfolders and the `Duplicates`
and `Duplicates - Review` folders under each root are covered — which means a
name present in both a month folder and its `Duplicates` folder resolves to
whichever the walk reaches first. If that matters, exclude `Duplicates*` in
`_find_document`.

### 12.4 The bank statement format — three shapes, not one

Written from the actual files, so `shim_bank_debits.py` need not guess. Sources:
`Bank Statements Cafe/Processed/<YYYY_MM>/` (5 workbooks with matching PDFs),
plus newer statements sitting in `INBOX TO FILE`.

**Shape A — current CBA export.** Sheets `Bank Transactions` and
`Account Details`. Row 1 of the first sheet:

```
Date | Transaction Details | Value Date | Debit | Credit | Balance
```

`Date` and `Value Date` are `DD/MM/YYYY` strings; `Value Date` is populated for
card transactions and empty for direct credits. Amounts are numbers. A row
carries a Debit or a Credit, never both. `Balance` is the running balance after
the row. Rows ascend by date.

```
01/09/2026 | VILI S FAMILY BAKERY MILE END SOUT AU | 28/08/2026 | 397.97 |  | 3690.39
01/09/2026 | Direct Credit <redacted> SQUARE AU PTY LT |      |        | 255.84 | 3844.08
```

**Shape B — older export, same header.** `Value Date` is empty and the value
date, the amount and the resulting balance are all embedded in the description:

```
01/10/2025 | MITOLO COFFEE WELLAND AU Card xx**** Value Date: 30/09/2025 40.21 $ $9,217.30 CR | | 40.21 | | 9217.30
```

**Shape C — a different export entirely.** One sheet, named with the account
number. No `Balance` column, different header, leading spaces in two of them,
`Process date` a real datetime rather than a string, and rows in **descending**
date order:

```
Process date | Description | Currency Code | " Debit" | " Credit"
2026-08-29 00:00:00 | ZAI*OM FleurMilk OM754 Sydney AU Card xx**** Value Date: 27/08/2026 | AUD | 131.50 |
```

The two `Cafe CBA Acc ... invoices required - <range>.csv` files at the top level
of `Finance and Data` are Shape C saved as CSV (67 and 81 rows, 45 and 54
carrying a debit). They are already the "debits awaiting an invoice" subset, which
is close to what the matching feature wants, but they are a derived extract. The
workbook is the source.

**What this means for the producer.** It must detect the shape from the header
rather than assume one: normalise to `{process_date, description, value_date,
debit, credit, balance_or_none}`, read the value date from the column when
present and parse `Value Date: DD/MM/YYYY` out of the description when not, and
treat an embedded amount as a cross-check on the Debit column rather than a
second source of truth.

**Identity needs care, and `seq` from sheet position will not do it.** Shape C
has no `Balance`, so balance cannot be part of a universal key; and row position
is not stable, because the exports overlap — `2026_08_01 to 2026_09_13` and
`2026_09_01 to 2026_09_13 (trimmed for import)` cover the same days, in
different shapes, with different row counts. A `seq` taken from the sheet would
give the same debit two different `record_uid`s and land it twice.

Use instead: `{account_ref, process_date, debit, description, occurrence}`, where
`occurrence` is the ordinal among rows that are otherwise identical on those four
fields, assigned after sorting the file deterministically (by process date, then
amount, then description). Genuinely repeated debits stay distinct, and a
re-export of the same period computes the same uid for each. `account_ref` should
be a stable label Tom chooses, not the account number, which should not travel in
a staging payload.

Still needed before building: which of these files Tom will actually feed it, and
whether `bank_debit` is promoted to a `cafe` table or staged as match-only — the
registry needs a `target_schema`/`target_table` either way.

### 12.5 The running app does not have HANDOVER-2's code

`~/Desktop/Finance and Data/Apps/verifier-app/` is a git repo on branch
`verifier-app-import`, not on `claude/bowerbird-verifier-handover-i7t4ke`.
Migration 021 is not on that disk. Nothing in `HANDOVER-2.md` section 2 is
running anywhere, and the `gst_assessed` fix in 12.1 has to be made on the
working branch, not in the Desktop copy, unless Tom pulls first.

To put the rule bodies where an offline session can read them:

```bash
psql kws115 -At -c "SELECT body FROM normalisation.v_rules_current WHERE rule_id='RULE-SQL'" > db/RULE-SQL-v8.txt
```

The same command with any `rule_id` serves the rest; `db/RULE-STG-draft-body.txt`
is the existing precedent for keeping a rule body in the repo.

### 12.6 Migration 021 checked against RULE-SQL v8 — passes

`db/RULE-SQL-v8.txt` is now in the repo, so the check HANDOVER-2 section 4 asked
for has been done. All nine pre-flight points, mechanically:

| Point | Result |
|---|---|
| 1 column metadata for every relation touched | `cafe.invoices` takes only an `ALTER TABLE ADD COLUMN`, no INSERT, so nullability does not arise. `staging.record_type.field_spec` is `jsonb NOT NULL` with **no default** and is neither generated nor identity — so a `jsonb_set` that returned NULL would abort rather than corrupt. See the note below on `information_schema`. |
| 2 backslash meta-commands / non-ASCII | 0 and 0 |
| 3 double-hyphen comments | 0 |
| 4 pglast, raw vs whitespace-collapsed | 20 statements both ways, no parse error. `AlterTableStmt`, `CommentStmt`, `DoStmt`, `SelectStmt`, `TransactionStmt`, `UpdateStmt` |
| 5 constraints, indexes, triggers | `cafe.invoices`: PK, two FKs, `UNIQUE (supplier_name, invoice_number)`, a CHECK on `payment_status` the script writes no literal into, no triggers. `staging.record_type`: PK on `record_type`, one FK, no triggers. **No partial unique index anywhere here**, so no mid-transaction ordering trap of the `rule_versions_one_current` kind. Both idempotency guards key on `record_type`, which is the primary key. |
| 6 execute every read-only statement | All run. `cafe.invoices.defect_log` absent (0 rows, as expected before STEP 1); `cafe_invoice` declares `defect_log` 0 times, so STEP 2 fires; `gst_assessed` hidden 0, declared exactly 1, so STEP 3's guard fires once and the closing assertions will hold after it |
| 7 DO-block DECLAREs vs aliases | `$preflight$` declares `v_types`, no aliases. `$verify$` declares `v_col`, `v_defect`, `v_hidden`, `v_fields`; aliases `a`, `rt`, `f`. Intersection empty, and every variable carries the `v_` prefix the rule recommends |
| 8 rule versions | None written; the script says so |
| 9 defect ID literals | None |

Also confirmed: three `BEGIN`/`COMMIT` pairs, no `ROLLBACK` outside the header
comment, and the registry shape the script assumes is the real one —
`field_spec` is an object of `fields`, `natural_key`, `party_field`, with 13
fields on `cafe_line` and 7 on `cafe_invoice`.

**One divergence worth a decision.** RULE-SQL point 1 mandates
`information_schema.columns`. Migration 021 uses `pg_catalog.pg_attribute`, and
so did this check, because `information_schema` is privilege-filtered and has
already hidden a column from a pre-flight in this project (HANDOVER.md section
10). The script follows the safer practice and departs from the letter of the
rule. That is a rule-maintenance question, not a fault in the script: RULE-SQL
point 1 should probably name `pg_catalog`.
