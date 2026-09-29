"""
shim_invoice_staging.py - transitional producer for the uniform staging
envelope.

Reads the two existing weekly workbooks and writes envelope JSONL into the
Staging Inbox, so the record based path can be built and proved without the
weekly-inbox-filing-review task changing at all. When that task learns to
emit JSONL directly, this file is deleted and nothing else moves.

    python3 shim_invoice_staging.py [--inbox DIR] [--dry-run]

Reads (paths from the environment, same variables the app already uses):
    VERIFIER_INVOICE_SUMMARY_PATH
    VERIFIER_LINE_ITEMS_PATH
Writes (path from the environment, default alongside them):
    VERIFIER_STAGING_INBOX

Neither workbook is modified, cleared or archived. They are shared with the
115KW/117KW side of the pipeline, which this does not own.

Envelope shape, one JSON object per line:

    schema_version, record_uid, batch_id, record_type, parent_uid, seq,
    produced_by, produced_at, natural_key, payload, provenance

record_uid is sha256(record_type + "|" + canonical_json(natural_key)), so a
rerun over the same workbook produces byte identical uids and the ingester
dedupes on identity rather than on a per feed rule.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import sys

import pandas as pd

from staging_envelope import (  # noqa: F401 - re-exported so the
    PRODUCED_BY, SCHEMA_VERSION, batch_id_for, envelope,  # other
    record_uid, write_batch,                              # producers
)                                                         # keep working
from workbook_values import as_text, clean, to_bool  # noqa: F401


# The workbook types these two columns as free text and has not been
# consistent about them: both "Inward" and "Inwards" appear across batches.
# Compare on a normalised key, never an exact string.
CAFE_CATEGORIES = {"cafe", "café"}
INWARD_DIRECTIONS = {"inward", "inwards"}
KW_CATEGORIES = {"115kw", "117kw"}

# Fields the destination stores as text, whatever pandas made of the cell.
TEXT_FIELDS = {"invoice_number", "payment_status", "property_code", "description",
               "category", "item", "expense_type", "surcharge_source"}

INVOICE_PAYLOAD_FIELDS = [
    "invoice_number",
    "invoice_date",
    "amount_ex_gst",
    "gst_amount",
    "amount_inc_gst",
    "payment_status",
]

KW_PAYLOAD_FIELDS = [
    "invoice_number",
    "invoice_date",
    "amount_ex_gst",
    "gst_amount",
    "amount_inc_gst",
    "payment_status",
]

LINE_PAYLOAD_FIELDS = [
    "purchase_date",
    "category",
    "item",
    "qty",
    "unit_cost",
    "line_total",
    "gst_applicable",
    "gst_declared",
    "gst_assessed",
    "expense_type",
    "surcharge_source",
    "in_invoice_total",
]


def norm_key(value):
    return str(value).strip().lower()


def build_invoices(path, produced_at, stamp):
    df = pd.read_excel(path, sheet_name=0)
    rows = df[
        df["category"].map(norm_key).isin(CAFE_CATEGORIES)
        & df["direction"].map(norm_key).isin(INWARD_DIRECTIONS)
    ]
    batch = batch_id_for("cafe_invoice", stamp)
    records = []
    for _, r in rows.iterrows():
        filename = clean(r.get("filename"))
        if not filename:
            continue
        natural_key = {"filename": filename}
        payload = dict((f, clean(r.get(f))) for f in INVOICE_PAYLOAD_FIELDS)
        for _tf in TEXT_FIELDS.intersection(payload):
            payload[_tf] = as_text(payload[_tf])
        if payload.get("payment_status") is None:
            payload["payment_status"] = "Unpaid"
        provenance = {
            "source_document": filename,
            "source_workbook": os.path.basename(path),
            "party_name": clean(r.get("supplier")),
            "notes": clean(r.get("notes")),
        }
        records.append(
            envelope("cafe_invoice", natural_key, payload, provenance,
                     produced_at, batch)
        )
    return batch, records


def build_kw_invoices(path, produced_at, stamp):
    """
    115KW and 117KW building invoices, from the same summary workbook the cafe
    rows come from. They have been sitting in that file unread since the app
    was built, because it filtered for Cafe only.

    Outward invoices are deliberately excluded: they are out of scope until it
    is settled whether accounting.invoices or accounting.outward_invoices is
    authoritative for them. They are counted and reported rather than dropped
    in silence.
    """
    df = pd.read_excel(path, sheet_name=0)
    is_kw = df["category"].map(norm_key).isin(KW_CATEGORIES)
    rows = df[is_kw & df["direction"].map(norm_key).isin(INWARD_DIRECTIONS)]
    outward = int((is_kw & ~df["direction"].map(norm_key).isin(INWARD_DIRECTIONS)).sum())

    batch = batch_id_for("kw_invoice", stamp)
    records = []
    for _, r in rows.iterrows():
        filename = clean(r.get("filename"))
        if not filename:
            continue
        natural_key = {"filename": filename}
        payload = dict((f, clean(r.get(f))) for f in KW_PAYLOAD_FIELDS)
        for _tf in TEXT_FIELDS.intersection(payload):
            payload[_tf] = as_text(payload[_tf])
        payload["property_code"] = str(clean(r.get("category")) or "").strip().upper()
        payload["description"] = None
        payload["notes"] = None
        provenance = {
            "source_document": filename,
            "source_workbook": os.path.basename(path),
            "party_name": clean(r.get("supplier")),
            "notes": clean(r.get("notes")),
        }
        records.append(
            envelope("kw_invoice", natural_key, payload, provenance, produced_at, batch)
        )
    return batch, records, outward


def build_lines(path, invoice_uids, produced_at, stamp):
    """
    seq is the line's position within its own invoice, and it is part of the
    natural key. That is deliberate: an invoice can legitimately carry
    several identical lines (a handful of the same linen item at the same
    price), and any key built from content alone silently drops them.
    """
    df = pd.read_excel(path, sheet_name=0)
    batch = batch_id_for("cafe_line", stamp)
    records = []
    orphans = {}
    counters = {}
    for _, r in df.iterrows():
        filename = clean(r.get("filename"))
        if not filename:
            continue
        if filename not in invoice_uids:
            orphans[filename] = orphans.get(filename, 0) + 1
            continue
        seq = counters.get(filename, 0) + 1
        counters[filename] = seq
        natural_key = {"filename": filename, "seq": seq}
        payload = dict((f, clean(r.get(f))) for f in LINE_PAYLOAD_FIELDS)
        for _tf in TEXT_FIELDS.intersection(payload):
            payload[_tf] = as_text(payload[_tf])
        payload["gst_applicable"] = to_bool(r.get("gst_applicable"))
        in_total = clean(r.get("in_invoice_total"))
        payload["in_invoice_total"] = True if in_total is None else to_bool(in_total)
        provenance = {
            "source_document": filename,
            "source_workbook": os.path.basename(path),
            "party_name": clean(r.get("supplier")),
            "notes": clean(r.get("notes")),
        }
        records.append(
            envelope("cafe_line", natural_key, payload, provenance,
                     produced_at, batch,
                     parent_uid=invoice_uids[filename], seq=seq)
        )
    return batch, records, orphans


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--summary", default=os.environ.get("VERIFIER_INVOICE_SUMMARY_PATH"))
    ap.add_argument("--lines", default=os.environ.get("VERIFIER_LINE_ITEMS_PATH"))
    ap.add_argument("--dry-run", action="store_true",
                    help="build and report, write nothing")
    ap.add_argument("--only", choices=["kw_invoice", "cafe"], default=None,
                    help="emit only this family. Useful when replaying an archived "
                         "workbook for one record type without dragging its other "
                         "rows into staging alongside.")
    args = ap.parse_args()

    needed = [("--summary", args.summary)]
    if args.only != "kw_invoice":
        needed.append(("--lines", args.lines))
    missing = [n for n, v in needed if not v]
    if missing:
        sys.exit("ERROR: no path for {0}. Set the matching VERIFIER_ variable "
                 "or pass the flag.".format(", ".join(missing)))
    for path in [p for p in (args.summary, args.lines) if p]:
        if not os.path.exists(path):
            sys.exit("ERROR: file not found: {0}".format(path))
    if not args.inbox and not args.dry_run:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")
    if args.inbox and not args.dry_run:
        os.makedirs(args.inbox, exist_ok=True)

    now = dt.datetime.now(dt.timezone.utc)
    produced_at = now.isoformat()
    stamp = now.strftime("%Y%m%dT%H%M%SZ")

    want_kw = args.only in (None, "kw_invoice")
    want_cafe = args.only in (None, "cafe")

    kw_batch, kw_invoices, outward_skipped = (
        build_kw_invoices(args.summary, produced_at, stamp) if want_kw
        else (batch_id_for("kw_invoice", stamp), [], 0))

    if want_cafe:
        inv_batch, invoices = build_invoices(args.summary, produced_at, stamp)
        invoice_uids = dict(
            (rec["natural_key"]["filename"], rec["record_uid"]) for rec in invoices
        )
        line_batch, lines, orphans = build_lines(args.lines, invoice_uids, produced_at, stamp)
    else:
        inv_batch, invoices = batch_id_for("cafe_invoice", stamp), []
        line_batch, lines, orphans = batch_id_for("cafe_line", stamp), [], {}

    def emit(batch, rtype, records, source):
        if not records:
            return "(none)", {"sha256": "-"}
        return write_batch(args.inbox, batch, rtype, records, produced_at,
                           source, args.dry_run)

    kw_name, kw_manifest = emit(kw_batch, "kw_invoice", kw_invoices, args.summary)
    inv_name, inv_manifest = emit(inv_batch, "cafe_invoice", invoices, args.summary)
    line_name, line_manifest = emit(line_batch, "cafe_line", lines, args.lines)

    print("mode        : {0}".format("DRY RUN, nothing written" if args.dry_run else "written"))
    print("inbox       : {0}".format(args.inbox or "(none)"))
    print("kw invoices : {0} records -> {1}".format(len(kw_invoices), kw_name))
    print("             sha256 {0}".format(kw_manifest["sha256"]))
    if outward_skipped:
        print("             ({0} outward KW row(s) skipped - out of scope)".format(outward_skipped))
    print("invoices    : {0} records -> {1}".format(len(invoices), inv_name))
    print("             sha256 {0}".format(inv_manifest["sha256"]))
    print("lines       : {0} records -> {1}".format(len(lines), line_name))
    print("             sha256 {0}".format(line_manifest["sha256"]))
    if orphans:
        print("orphan lines: {0} line(s) across {1} filename(s) had no matching "
              "invoice in the summary workbook and were NOT emitted:"
              .format(sum(orphans.values()), len(orphans)))
        for filename in sorted(orphans):
            print("    {0} x {1}".format(orphans[filename], filename))
    else:
        print("orphan lines: none")


if __name__ == "__main__":
    main()
