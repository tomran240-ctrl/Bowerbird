# Bowerbird Verifier

Reviews café invoices (header + line items) from the real weekly-inbox-
filing-review pipeline before they're imported into 115kws.

This is a rebuild — an earlier version of this app was built against an
imagined pipeline (`document-filing`, a CSV, invoice headers only) that
turned out not to be the real process. This version is built against the
actual `Invoice Summary - Pending.xlsx` output and the real `cafe.invoices`
/ `cafe.purchases` schema.

## What's here

```
db/
  001_verifier_schema.sql        <- already run against 115kws
  002_cafe_line_items.sql        <- run this next - restructures
                                     staging.cafe_invoices for the real
                                     column set, adds staging.cafe_purchases
  000_test_replica_only.sql      <- NOT for 115kws, local testing only
backend/
  main.py                        <- FastAPI app - invoice + line-item model
  ingest_invoice_summary.py      <- loads Cafe/Inward rows from
                                     Invoice Summary - Pending.xlsx
  ingest_cafe_line_items.py      <- loads Cafe Line Items - Pending.xlsx,
                                     links each line to its parent invoice
  requirements.txt
  static/                        <- the UI
```

## One-time setup on the iMac

You already ran `001_verifier_schema.sql` and created the `verifier_app`
role. Now:

1. **Run the follow-up migration** — `db/002_cafe_line_items.sql` — against
   115kws. Read the comment at the top first: it clears the handful of
   fictional test rows sitting in `staging.cafe_invoices` from testing the
   earlier scaffold, and restructures that table around `filename` instead
   of the old placeholder `record_id`/`pdf_path` columns. If you've staged
   anything real in there since, stop and say so before running it.
2. **Run migration 003** — `db/003_supplier_picker.sql` — grants the app's
   role write access to `contacts.organisations` (for the "+ New supplier"
   button) and `UPDATE` on `normalisation.supplier_aliases` (the alias
   upsert needs this in addition to the `INSERT` already granted in 001).
2. **Install the two new dependencies**:
   ```
   cd backend
   python3 -m pip install -r requirements.txt
   ```
   (adds `pandas` and `openpyxl`, needed to read the real .xlsx files)
3. **Point `VERIFIER_PDF_ROOT` at the real inbox**, not a `Filed/` folder —
   renamed invoice PDFs stay directly in `INBOX TO FILE` until a separate
   filing step moves them:
   ```
   export VERIFIER_PDF_ROOT="/Users/admin/Desktop/INBOX TO FILE"
   ```
4. **Point the app at the two real staging workbooks**, so it can check
   for new data itself (see "Getting data in" below):
   ```
   export VERIFIER_INVOICE_SUMMARY_PATH="/Users/admin/Desktop/Finance and Data/Invoice Staging/Invoice Summary - Pending.xlsx"
   export VERIFIER_LINE_ITEMS_PATH="/Users/admin/Desktop/Finance and Data/Invoice Staging/Cafe Line Items - Pending.xlsx"
   ```
5. **Run it** the same as before:
   ```
   python3 -m uvicorn main:app --host 127.0.0.1 --port 8420
   ```

## Getting data in

**Automatic (the normal path now).** Set two more environment variables
pointing at the real staging workbooks, and the app checks both for new
rows every time the home page loads (and via the Refresh button):

```
export VERIFIER_INVOICE_SUMMARY_PATH="/Users/admin/Desktop/Finance and Data/Invoice Staging/Invoice Summary - Pending.xlsx"
export VERIFIER_LINE_ITEMS_PATH="/Users/admin/Desktop/Finance and Data/Invoice Staging/Cafe Line Items - Pending.xlsx"
```

Add these alongside `VERIFIER_DB_URL` and `VERIFIER_PDF_ROOT` before running
uvicorn. If either variable isn't set, or the file it points to doesn't
exist yet, auto-ingest is silently skipped — nothing breaks, it just won't
find anything new until the file shows up.

**What "double handling" protection actually is, and where it lives:**
- Invoices dedupe on `filename` — enforced twice: once as an application
  check before inserting, and once as a real database UNIQUE index
  (`idx_staging_cafe_invoices_filename`) as a backstop. A filename already
  in staging, in *any* status (pending, verified, or already imported),
  is never inserted again. This is what actually matters: since the source
  workbook is never cleared (see below), it will keep containing invoices
  from many weeks back on every future refresh — the filename check is
  what stops those from being re-staged or re-verified every time.
- Line items dedupe on (parent invoice, item, amount) — best-effort, since
  there's no natural unique key at the line level the way `filename`
  serves invoices.
- At Import, there's a *third* independent check against production
  itself: a `(supplier_name, invoice_number)` pair already in
  `cafe.invoices` blocks that invoice's import, regardless of what
  staging thinks. This catches the case a filename-based check can't —
  the same real-world invoice somehow arriving under a different filename
  in a later batch.

**Manual (still available).** The two CLI scripts still work standalone,
useful for checking a file without opening the app, or if auto-ingest
ever needs debugging:

```
python3 ingest_invoice_summary.py "path/to/Invoice Summary - Pending.xlsx"
python3 ingest_cafe_line_items.py "path/to/Cafe Line Items - Pending.xlsx"
```

Both the manual scripts and the app's auto-ingest now share one
implementation (`ingest_lib.py`) — there's no separate copy of the
matching/dedup logic to drift out of sync.

**Neither path clears or archives the source .xlsx.** Unlike the old CSV
design, these files are shared with the 115KW/117KW side of the pipeline
too, which this app doesn't own — clearing them here would destroy rows
meant for a different review process. That's someone else's call, not
this app's. The dedup mechanism above is specifically what makes leaving
the file alone safe to do.

## How verification works

- Each invoice is a unit: a header (supplier, invoice number, date, the
  three GST totals, payment status, notes) plus zero or more line items.
- The header has its own **Header verified** checkbox. Each line has its
  own verify checkbox, plus a **Verify all lines** button for the ones
  that don't need individual attention.
- **Supplier matching is now correctable, not just informational.** The
  "Matched contact" field is a live search against `contacts.organisations`
  — type to filter, click to confirm. There's also a **+ New** button for
  registering a supplier that isn't there yet, which assigns the next
  `ORG-NNN` number automatically. Either action immediately clears the
  flag and writes (or corrects) an entry in `normalisation.supplier_aliases`
  — no need to wait for header verification first. This matters because
  the fuzzy matcher can be confidently wrong: on the very first real batch,
  it matched "Alsco Linen" to "Adelaide Council" at 41% — the picker is
  how you fix that in two clicks instead of fighting the auto-match.
- A **reconciliation banner** shows live whether the line items (summed,
  GST included, excluding surcharge/adjustment lines marked outside the
  invoice total) add up to the header's inc-GST figure. This is
  informational, not a hard block — matching the source task's own
  guidance that a genuine mismatch should still be staged and reported,
  not hidden or forced to balance.
- An invoice becomes **ready to import** once the header is verified and
  every one of its lines is verified (an invoice with zero staged lines
  counts as ready on the header alone).

## Import

Hard-blocks (checked before anything is written, whole batch rolls back
together if any invoice fails):
- `(supplier_name, invoice_number)` already in `cafe.invoices`
- a `supplier_id` that doesn't exist in `contacts.organisations`
- a verified line with an invalid `expense_type`
- a `surcharge_source` set on a line whose category isn't
  `Cafe - Card Surcharge` / `Cafe - Adjustment`
- a line excluded from the invoice total (`in_invoice_total = false`)
  whose category isn't one of those same two

On success, each invoice's verified lines import into `cafe.purchases`
with `gst_status = 'Auto'` — matching the source pipeline's own note that
line items land awaiting GST confirmation, not pre-confirmed.

## Still not done

- No Tailscale exposure yet — still bound to `127.0.0.1` only.
- Only café invoices. The 115KW/117KW side of Invoice Summary - Pending.xlsx,
  and bank statement staging, are different review processes this app
  doesn't touch.
