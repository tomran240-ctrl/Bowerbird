"""
shim_payroll_hours.py - stage the weekly Square hours run.

    python3 shim_payroll_hours.py --dry-run
    python3 shim_payroll_hours.py
    python3 shim_payroll_hours.py --week 2026-09-14

Reads payroll_ledger.jsonl - the file the Friday scheduled task appends to -
and emits payroll_hours_run parents with their payroll_hours_line children in
the staging envelope.

WHAT THIS SIDE IS FOR
    Cafe staff are paid their ROSTERED hours. The time clock verifies
    attendance and does not adjust pay. So the figure that matters here is
    rostered_minutes; the clock variances travel with it as information.

    The ledger calls rostered + adj_a + adj_b "payable_minutes". Nobody is
    paid that. It is carried across as clocked_minutes, named for what it is,
    and the ledger key is left alone so the scheduled task's own continuity
    chain is untouched.

WHY THE LEDGER AND NOT THE PDF
    The ledger is already the structured form: integer minutes, a per-person
    breakdown, and the run's own assertion that the lines sum to the totals.
    The PDF is a rendering of it. Parsing the rendering of a file you already
    have is how a transcription error gets invented.

WHAT IS CHECKED BEFORE ANYTHING IS EMITTED
    Every row must satisfy rostered + adj_a + adj_b = payable, at the run
    level and on every line, and the lines must sum to each of the four run
    totals. The scheduled task asserts this before it writes; asserting it
    again here is not redundant, because a hand-edited ledger is exactly the
    kind of thing that would otherwise reach production unnoticed.

    A row that fails is reported and skipped. The rest of the file still
    stages - unlike a malformed batch, one bad ledger line does not make the
    others untrustworthy.
"""

import argparse
import datetime as dt
import json
import os
import sys

from staging_envelope import (
    PRODUCED_BY, SCHEMA_VERSION, batch_id_for, envelope, write_batch,
)

RUN = "payroll_hours_run"
LINE = "payroll_hours_line"

RUN_DATE_FIELDS = ("settled_from", "settled_to", "carryback_from",
                   "carryback_to", "deferred_from", "deferred_to")
RUN_COUNT_FIELDS = ("exceptions_action", "exceptions_review", "exceptions_note")


def hours(minutes):
    """Minutes to decimal hours, two places - the house convention, and what
    the grid, the instruction side and the variance view all speak.

    The ledger's integer minutes stay the exact quantity in the database,
    because clocked = rostered + adj_a + adj_b is exact in minutes and is not
    exact in hours rounded to two places: 60.25 + -2.68 + 0.12 comes to 57.69
    where 3461 minutes is 57.68. Going this direction is safe. The result is
    within 0.005 h of the true value, so multiplying back by 60 lands within
    0.3 of the original minute count, and 0.3 rounds to the same integer every
    time. The promoter reconstructs minutes that way and the CHECK on the
    table verifies it rather than taking it on trust.
    """
    return round(minutes / 60.0, 2)


def check_row(row):
    """-> list of complaints, empty when the row is sound."""
    bad = []
    need = ("pay_week_start", "pay_week_end", "run_date", "rostered_minutes",
            "adj_a_minutes", "adj_b_minutes", "payable_minutes", "lines")
    for key in need:
        if key not in row:
            bad.append("missing key %s" % key)
    if bad:
        return bad

    r, a, b, p = (row["rostered_minutes"], row["adj_a_minutes"],
                  row["adj_b_minutes"], row["payable_minutes"])
    if r + a + b != p:
        bad.append("run totals do not add up: %d + %d + %d <> %d" % (r, a, b, p))

    start = dt.date.fromisoformat(row["pay_week_start"])
    end = dt.date.fromisoformat(row["pay_week_end"])
    if (end - start).days != 6:
        bad.append("pay week is %d days, not 7" % ((end - start).days + 1))

    if not row["lines"]:
        bad.append("no lines")
        return bad

    for ln in row["lines"]:
        for key in ("team_member_id", "staff_name", "rostered_minutes",
                    "adj_a_minutes", "adj_b_minutes", "payable_minutes"):
            if key not in ln:
                bad.append("a line is missing %s" % key)
                return bad
        if (ln["rostered_minutes"] + ln["adj_a_minutes"] + ln["adj_b_minutes"]
                != ln["payable_minutes"]):
            bad.append("line for %s does not add up" % ln["staff_name"])

    ids = [ln["team_member_id"] for ln in row["lines"]]
    if len(ids) != len(set(ids)):
        bad.append("the same team member appears twice in one run")

    for key, total in (("rostered_minutes", r), ("adj_a_minutes", a),
                       ("adj_b_minutes", b), ("payable_minutes", p)):
        got = sum(ln[key] for ln in row["lines"])
        if got != total:
            bad.append("lines sum to %d for %s, the run says %d"
                       % (got, key, total))
    return bad


def build(rows, produced_at, stamp):
    parents, children, report = [], [], []
    for row in rows:
        week = row["pay_week_start"]
        note = ["Square roster and timecards for the pay week."]
        if row.get("note"):
            note.append(row["note"])
        note.append("clocked_minutes is the ledger's payable_minutes; it is "
                    "an attendance figure and is not what anyone is paid.")

        prov = {
            "source_document": "payroll_ledger.jsonl",
            "source_workbook": None,
            "party_name": None,
            "notes": " ".join(note),
        }

        payload = {
            "pay_week_end": row["pay_week_end"],
            "run_date": row["run_date"],
            "rostered_hours": hours(row["rostered_minutes"]),
            "adj_a_hours": hours(row["adj_a_minutes"]),
            "adj_b_hours": hours(row["adj_b_minutes"]),
            "clocked_hours": hours(row["payable_minutes"]),
            "generated": row.get("generated"),
            "notes": None,
        }
        for f in RUN_DATE_FIELDS:
            payload[f] = row.get(f)
        for f in RUN_COUNT_FIELDS:
            payload[f] = row.get(f, 0)

        parent = envelope(RUN, {"pay_week_start": week}, payload, prov,
                          produced_at, batch_id_for(RUN, stamp))
        parents.append(parent)

        ordered = sorted(row["lines"],
                         key=lambda l: (-l["rostered_minutes"],
                                        l["team_member_id"]))
        for seq, ln in enumerate(ordered, start=1):
            children.append(envelope(
                LINE,
                {"pay_week_start": week,
                 "square_team_member_id": ln["team_member_id"],
                 "seq": seq},
                {"staff_name": ln["staff_name"],
                 "role": ln.get("role"),
                 "rostered_hours": hours(ln["rostered_minutes"]),
                 "adj_a_hours": hours(ln["adj_a_minutes"]),
                 "adj_b_hours": hours(ln["adj_b_minutes"]),
                 "clocked_hours": hours(ln["payable_minutes"]),
                 "notes": None},
                {"source_document": "payroll_ledger.jsonl",
                 "source_workbook": None,
                 "party_name": None,
                 "notes": "Line %d of the run for the week beginning %s."
                          % (seq, week)},
                produced_at, batch_id_for(LINE, stamp),
                parent_uid=parent["record_uid"], seq=seq))

        report.append((week, row["pay_week_end"], len(ordered),
                       row["rostered_minutes"], row["payable_minutes"],
                       row.get("exceptions_action", 0)))
    return parents, children, report


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ledger", default=os.environ.get("VERIFIER_PAYROLL_LEDGER"))
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--week", help="one pay_week_start, YYYY-MM-DD")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.ledger:
        sys.exit("ERROR: no ledger. Set VERIFIER_PAYROLL_LEDGER or pass "
                 "--ledger.")
    if not os.path.exists(args.ledger):
        sys.exit("ERROR: no ledger at %s" % args.ledger)
    if not args.inbox and not args.dry_run:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")

    rows, skipped = [], []
    with open(args.ledger, "r", encoding="utf-8") as fh:
        for n, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except ValueError as exc:
                skipped.append(("line %d" % n, "not JSON: %s" % exc))
                continue
            if args.week and row.get("pay_week_start") != args.week:
                continue
            bad = check_row(row)
            if bad:
                skipped.append((row.get("pay_week_start", "line %d" % n),
                                "; ".join(bad)))
                continue
            rows.append(row)

    seen = {}
    for row in rows:
        seen.setdefault(row["pay_week_start"], 0)
        seen[row["pay_week_start"]] += 1
    dupes = [w for w, c in seen.items() if c > 1]
    if dupes:
        sys.exit("ERROR: the ledger holds more than one row for pay week(s) "
                 "%s. pay_week_start is the natural key, so this must be "
                 "resolved in the ledger before staging." % ", ".join(sorted(dupes)))

    produced_at = dt.datetime.now(dt.timezone.utc).isoformat()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    parents, children, report = build(rows, produced_at, stamp)

    print("Square hours runs from %s\n" % args.ledger)
    print("   %-12s %-12s %5s %9s %9s  %s"
          % ("WEEK FROM", "WEEK TO", "STAFF", "ROSTERED", "CLOCKED", "ACTIONS"))
    for start, end, n, rost, clock, acts in report:
        print("   %-12s %-12s %5d %9.2f %9.2f  %d"
              % (start, end, n, rost / 60.0, clock / 60.0, acts))
    print("\n   %d run(s), %d line(s)" % (len(parents), len(children)))
    print("   rostered is the pay basis; clocked is attendance only")

    if skipped:
        print("\nSKIPPED - these ledger rows did not check out:")
        for who, why in skipped:
            print("   %s\n      %s" % (who, why))

    if not parents:
        print("\nNothing to stage.")
        return 1 if skipped else 0

    if args.dry_run:
        print("\nDry run. Nothing written.")
        return 1 if skipped else 0

    for rtype, records in ((RUN, parents), (LINE, children)):
        name, manifest = write_batch(args.inbox, batch_id_for(rtype, stamp),
                                     rtype, records, produced_at,
                                     args.ledger, False)
        print("\n   wrote %-26s %4d record(s)  sha256 %s"
              % (name, manifest["row_count"], manifest["sha256"][:16]))

    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
