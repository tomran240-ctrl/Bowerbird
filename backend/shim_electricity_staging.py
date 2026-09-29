"""
shim_electricity_staging.py - transitional producer for electricity batches.

Reads the three electricity workbooks the weekly review writes and emits
envelope JSONL into the Staging Inbox, so meter bills go through review
instead of straight into accounting.* by hand-run SQL.

    python3 shim_electricity_staging.py [--dry-run]

Paths come from the environment (see staging_env.sh), or pass them:
    --bills    Electricity Bills - Pending.xlsx
    --charges  Electricity Charges - Pending.xlsx
    --other    Electricity Other Charges - Pending.xlsx

SIX RECORD TYPES, NOT THREE. Main and tenancy meters go to different
destination tables with genuinely different columns, so a bill becomes
either elec_main_bill or elec_ind_bill according to its meter_type, and its
charges follow their parent. A tenancy charge therefore drops charge_group,
dlf and mlf - individual_meter_bill_charges has no such columns. That drop
is counted and reported at the end rather than done in silence.

NOTHING HERE IS A BACKFILL. The 206 meter bills already in accounting.* were
loaded by other means and are not touched. If an archived workbook is
replayed through this shim, its records stage normally and are then refused
at promotion by the (nmi, period) duplicate check - which is the intended
behaviour, not a failure.
"""

import argparse
import datetime as dt
import os
import sys

import pandas as pd

from staging_envelope import (
    PRODUCED_BY, batch_id_for, envelope, write_batch,
)
from workbook_values import as_text, clean, to_bool

# Fields the destination stores as text. NMIs and account numbers are bare
# digit strings and must never arrive as numbers.
TEXT_FIELDS = {"retailer", "invoice_number", "account_name", "account_number",
               "nmi", "invoice_type", "supply_address", "level", "read_type",
               "contract_type", "contract_status", "meter_number", "charge_group",
               "charge_type", "time_of_use", "unit_type", "description"}

MAIN_BILL_FIELDS = [
    "retailer", "invoice_number", "issue_date", "account_name", "account_number",
    "nmi", "invoice_type", "supply_address", "bill_period_start", "bill_period_end",
    "bill_period_days", "read_type", "amount_ex_gst", "gst_amount", "amount_inc_gst",
    "previous_balance", "payment_date", "payment_amount", "balance_brought_forward",
    "total_amount_due", "due_date",
]

IND_BILL_FIELDS = [
    "retailer", "issue_date", "account_name", "account_number", "nmi",
    "invoice_type", "supply_address", "level", "bill_period_start", "bill_period_end",
    "bill_period_days", "read_type", "contract_type", "contract_status",
    "avg_daily_usage_this_bill_kwh", "avg_daily_usage_last_year_kwh", "meter_number",
    "previous_balance", "payment_date", "payment_amount", "balance_brought_forward",
    "amount_ex_gst", "gst_amount", "amount_inc_gst", "direct_debit_amount",
    "direct_debit_date",
]

MAIN_CHARGE_FIELDS = ["charge_group", "charge_type", "time_of_use", "units",
                      "unit_type", "rate", "dlf", "mlf", "amount"]
IND_CHARGE_FIELDS = ["charge_type", "time_of_use", "units", "unit_type", "rate", "amount"]
OTHER_FIELDS = ["description", "amount", "gst_exempt"]

# Columns a tenancy charge carries in the workbook but its destination table
# does not have. Dropping them is correct; doing it quietly is not.
IND_CHARGE_DROPPED = ["charge_group", "dlf", "mlf"]

BILL_KEY = ("nmi", "bill_period_start", "bill_period_end")


def key_of(row):
    return (str(as_text(row.get("nmi"))),
            str(clean(row.get("bill_period_start"))),
            str(clean(row.get("bill_period_end"))))


def natural_key_of(row, seq=None):
    nk = {"nmi": as_text(row.get("nmi")),
          "bill_period_start": clean(row.get("bill_period_start")),
          "bill_period_end": clean(row.get("bill_period_end"))}
    if seq is not None:
        nk["seq"] = seq
    return nk


def build_bills(path, produced_at, stamp):
    df = pd.read_excel(path, sheet_name=0)
    out = {"elec_main_bill": [], "elec_ind_bill": []}
    parents = {}
    unknown_meter = 0

    for _, r in df.iterrows():
        meter = str(clean(r.get("meter_type")) or "").strip().lower()
        if meter == "main":
            rtype, fields = "elec_main_bill", MAIN_BILL_FIELDS
        elif meter == "individual":
            rtype, fields = "elec_ind_bill", IND_BILL_FIELDS
        else:
            unknown_meter += 1
            continue

        nk = natural_key_of(r)
        if nk["nmi"] is None:
            continue
        payload = dict((f, clean(r.get(f))) for f in fields)
        for _tf in TEXT_FIELDS.intersection(payload):
            payload[_tf] = as_text(payload[_tf])
        payload["notes"] = None
        provenance = {
            "source_document": clean(r.get("source_file")),
            "source_workbook": os.path.basename(path),
            "party_name": clean(r.get("retailer")),
            "notes": clean(r.get("notes")),
        }
        rec = envelope(rtype, nk, payload, provenance, produced_at,
                       batch_id_for(rtype, stamp))
        out[rtype].append(rec)
        parents[key_of(r)] = (rtype, rec["record_uid"])

    return out, parents, unknown_meter


def build_children(path, parents, produced_at, stamp, kind):
    """
    kind is 'charge' or 'other'. A child's record type follows its parent's,
    so a charge on a main meter and a charge on a tenancy meter are different
    types with different field sets, resolved here rather than guessed from
    which columns happen to be filled in.
    """
    df = pd.read_excel(path, sheet_name=0)
    out = {}
    counters = {}
    orphans = 0
    dropped = 0

    for _, r in df.iterrows():
        k = key_of(r)
        if k not in parents:
            orphans += 1
            continue
        parent_type, parent_uid = parents[k]
        main = parent_type == "elec_main_bill"

        if kind == "charge":
            rtype = "elec_main_charge" if main else "elec_ind_charge"
            fields = MAIN_CHARGE_FIELDS if main else IND_CHARGE_FIELDS
            if not main:
                for col in IND_CHARGE_DROPPED:
                    if clean(r.get(col)) is not None:
                        dropped += 1
                        break
        else:
            rtype = "elec_main_other_charge" if main else "elec_ind_other_charge"
            fields = OTHER_FIELDS

        seq = counters.get((rtype, k), 0) + 1
        counters[(rtype, k)] = seq

        payload = dict((f, clean(r.get(f))) for f in fields)
        for _tf in TEXT_FIELDS.intersection(payload):
            payload[_tf] = as_text(payload[_tf])
        if "gst_exempt" in payload:
            flag = to_bool(r.get("gst_exempt"))
            payload["gst_exempt"] = False if flag is None else flag

        provenance = {
            "source_workbook": os.path.basename(path),
            "parent_key": "%s %s to %s" % k,
        }
        out.setdefault(rtype, []).append(
            envelope(rtype, natural_key_of(r, seq), payload, provenance,
                     produced_at, batch_id_for(rtype, stamp),
                     parent_uid=parent_uid, seq=seq)
        )

    return out, orphans, dropped


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    folder = os.environ.get("VERIFIER_STAGING_INBOX", "")
    base = os.path.dirname(os.environ.get("VERIFIER_INVOICE_SUMMARY_PATH", "")) or "."
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--bills", default=os.path.join(base, "Electricity Bills - Pending.xlsx"))
    ap.add_argument("--charges", default=os.path.join(base, "Electricity Charges - Pending.xlsx"))
    ap.add_argument("--other", default=os.path.join(base, "Electricity Other Charges - Pending.xlsx"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.bills):
        print("No electricity bills workbook at:\n  %s" % args.bills)
        print("Nothing to do. Electricity arrives only when bills are processed.")
        return
    if not args.inbox and not args.dry_run:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")
    if args.inbox and not args.dry_run:
        os.makedirs(args.inbox, exist_ok=True)

    now = dt.datetime.now(dt.timezone.utc)
    produced_at = now.isoformat()
    stamp = now.strftime("%Y%m%dT%H%M%SZ")

    bills, parents, unknown_meter = build_bills(args.bills, produced_at, stamp)
    children = {}
    orphan_charges = orphan_other = dropped_cols = 0
    if os.path.exists(args.charges):
        got, orphan_charges, dropped_cols = build_children(
            args.charges, parents, produced_at, stamp, "charge")
        children.update(got)
    if os.path.exists(args.other):
        got, orphan_other, _ = build_children(
            args.other, parents, produced_at, stamp, "other")
        children.update(got)

    # Parents first: the ingester orders batches by registry depth anyway, but
    # emitting in this order keeps the inbox readable.
    everything = list(bills.items()) + list(children.items())
    print("mode        : %s" % ("DRY RUN, nothing written" if args.dry_run else "written"))
    print("inbox       : %s" % (args.inbox or "(none)"))
    total = 0
    for rtype, records in everything:
        if not records:
            continue
        name, manifest = write_batch(args.inbox, batch_id_for(rtype, stamp), rtype,
                                     records, produced_at, args.bills, args.dry_run)
        total += len(records)
        print("%-22s %4d records -> %s" % (rtype, len(records), name))
    print("total       : %d records" % total)
    if unknown_meter:
        print("WARNING     : %d bill row(s) had an unrecognised meter_type and were not "
              "emitted" % unknown_meter)
    if orphan_charges or orphan_other:
        print("orphans     : %d charge row(s) and %d other-charge row(s) had no matching "
              "bill in this batch and were NOT emitted" % (orphan_charges, orphan_other))
    if dropped_cols:
        print("dropped     : %d tenancy charge row(s) carried charge_group/dlf/mlf, which "
              "individual_meter_bill_charges has no column for" % dropped_cols)


if __name__ == "__main__":
    main()
