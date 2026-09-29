# Staging block for `weekly-inbox-filing-review`

Paste this into the task's instructions, replacing whatever tells it to write
`Invoice Summary - Pending.xlsx` and `Cafe Line Items - Pending.xlsx`.

Generated from the registry on 23 September 2026. Amended 29 September 2026:
`in_invoice_total` is now required - see the section on it below.
If a field or enum changes,
regenerate rather than edit: `staging.record_type` is authoritative, and
`staging.v_enum_from_destination` shows any enum that has drifted from its
destination.

---

## STAGE THE INVOICES YOURSELF

You are a producer under RULE-STG. You write the staging files directly. Do
NOT write to `Invoice Summary - Pending.xlsx` or `Cafe Line Items -
Pending.xlsx` any more; nothing reads them.

Never compute a record_uid, a hash, or a manifest. Write a JSON file and hand
it to the helper, which does all of that:

```
cd ~/Desktop/"Finance and Data"/Apps/verifier-app/backend
set -a; . ./staging_env.sh; set +a
python3 stage_records.py --in /tmp/staging_batch.json --dry-run
python3 stage_records.py --in /tmp/staging_batch.json
```

Always dry-run first. It refuses the whole file on any structural fault and
names each one; nothing is written until it is clean.

### The file you write

```json
{
  "produced_by": "weekly-inbox-filing-review",
  "batches": [
    {"record_type": "cafe_invoice", "records": [ ... ]},
    {"record_type": "cafe_line", "parent_type": "cafe_invoice", "records": [ ... ]},
    {"record_type": "kw_invoice", "records": [ ... ]}
  ]
}
```

Parents before children. Omit a batch entirely if it has no records.

### Each record

```json
{
  "natural_key": { ... },
  "payload":     { ... },
  "provenance":  {"source_document": "<the filed filename>",
                  "source_workbook": null,
                  "party_name": "<supplier as printed>",
                  "notes": "<your reasoning>"}
}
```

A child record adds `"parent_natural_key": {...}` and `"seq": <n>`, and its
own `natural_key` must contain that same seq.

### The three types

| type | natural_key | parent |
|---|---|---|
| `cafe_invoice` | `{"filename": "..."}` | — |
| `cafe_line` | `{"filename": "...", "seq": n}` | `cafe_invoice` |
| `kw_invoice` | `{"filename": "..."}` | — |

`filename` is the filed name under RULE-FN, exactly as the file was named.

**cafe_invoice payload** — `invoice_number`*, `invoice_date`*,
`amount_ex_gst`, `gst_amount`, `amount_inc_gst`*, `payment_status`*, `notes`,
`defect_log` (optional free text; usually left for the reviewer)

**cafe_line payload** — `purchase_date`*, `category`*, `item`*, `qty`,
`unit_cost`, `line_total`*, `gst_applicable`, `gst_declared`, `gst_assessed` (hidden in the app, still stored: it is the only
GST on many lines), `expense_type`*, `surcharge_source`, `in_invoice_total`*, `notes`

**kw_invoice payload** — `property_code`*, `invoice_number`*,
`invoice_date`*, `amount_ex_gst`, `gst_amount`, `amount_inc_gst`*,
`payment_status`, `description`, `notes`

`*` is required. A declared field you omit is null; a key the registry does
not declare is a rejected batch.

### Enums, exactly as written

- `payment_status` (cafe): `Unpaid`, `Paid`, `Partially Paid`, `Disputed`
- `payment_status` (115KW/117KW): `Paid`, `Unpaid`
- `property_code`: `115KW`, `117KW`
- `expense_type`: `COGS`, `Operating Expense`, `Non-Business`, `Capital`
- `surcharge_source`: `Invoice`, `Bank derived`, `Invoice residual`

`Invoice residual` is for an undisclosed surcharge found as a residual, per
RULE-CS v2. It is a real value and the database accepts it.

### Field shapes

- Money: numbers, not strings. No `$`, no thousands separator.
- Dates: `YYYY-MM-DD`. Never `DD/MM/YYYY`.
- Booleans: `true` / `false`. Never `1`, `0` or `"TRUE"`.
- Identifiers that look numeric are STRINGS — invoice numbers, account
  numbers, NMIs. `271069147` as a number fails at promotion.
- Trim every value. A trailing space defeats the duplicate guard.

### `in_invoice_total` is not optional

Set it explicitly on every line, `true` or `false`. This is the one field here
where leaving it out is worse than being wrong out loud.

`cafe.purchases.in_invoice_total` is `NOT NULL DEFAULT true`, so an omitted
value becomes `true` at promotion. That is right for an ordinary purchase line
and wrong for a line billed outside the invoice total, where it quietly adds
the amount to a total the reconciliation then checks against the document.
Nothing downstream can tell an omission from a deliberate `true`.

- `true` - the line is part of the invoice's printed total. Nearly every line.
- `false` - the line appears on the document but outside its total: a surcharge
  billed separately per RULE-AL, or a figure shown for information only.

Five lines in the 23 September batch left it null. They were ordinary
purchases, so the default happened to be correct and all seven invoices still
reconciled ex-GST. Getting away with it is not the same as it being safe.

### The two notes are different

`provenance.notes` is yours: what the document printed, which rule governed a
judgement, what a later reconciliation should expect. This is the main thing
you can record that no converter ever could — write it properly.

> "Surcharge billed on its own invoice, not a line on the linen invoice,
>  per RULE-AL."
> "Residual of $2.15 against the bank debit with no surcharge printed;
>  recorded as Invoice residual per RULE-CS v2."
> "Supplier shows 'Amount Applied' of $340; staged the printed invoice total
>  per RULE-AMT."

`payload.notes` belongs to whoever verifies in the app. **Leave it null.**

### If a batch is refused

Fix the cause and re-emit under a new run. Never reuse a `source_file` that
already ingested. A record you have already staged and then corrected is an
amendment: the ingester compares payloads, amends it while it is still
pending, and refuses the batch if it has already been verified or imported.

### What you no longer do

- No workbook writing for invoices.
- No record_uid, no sha256, no manifest, no file naming.
- No deciding whether something is a duplicate — `record_uid` handles it.
