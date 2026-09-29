"""
shim_payroll_instruction.py - stage the weekly pay instruction to IPS.

    python3 shim_payroll_instruction.py --dry-run
    python3 shim_payroll_instruction.py
    python3 shim_payroll_instruction.py --week 2026-09-20
    python3 shim_payroll_instruction.py --since 2026-09-01

Reads the archive of "Payroll - My Little Friend - 115KWS - <date>.pdf" and
emits payroll_instruction parents (one per business unit per week) with their
payroll_instruction_line children, in the staging envelope.

WHAT THIS DOCUMENT IS
    The weekly instruction to Integrated Payroll Solutions: who is paid and
    for how many hours, across 115connect, Cafe and Farm. It is the record of
    what was actually paid. The Square hours run is the other side of the
    comparison and has its own producer.

NEVER READ Time Record.xlsx
    That workbook holds one pay period at a time and is overwritten every
    week. The PDF archive is the durable record. Reading the workbook would
    give you this week and lose the other 46.

WHAT THE ARCHIVE TAUGHT THIS PARSER, each rule paid for by a real document

    TWO TEMPLATES. The Oct-Nov 2025 sheets head their sections
    "Admin - Building Management", "Cafe" and "Gardener", and abbreviate the
    employment class to "C". Later sheets use "115connect", "Cafe", "Farm"
    and "Casual". A parser that does not know the old headings files a row
    under whichever section came before it: that is how Michael Pielago, the
    gardener, first appeared as cafe staff. An unknown section heading
    therefore REJECTS the document rather than being ignored.

    TWO DATE FORMATS. 7/11/2025 in 45 documents, 26-Oct-25 in two. Day first
    in both. The period end is read from the document body and must equal the
    date in the filename; they agree in all 47 today, and a disagreement means
    a rename or a re-issue, which is a question rather than something to
    resolve by preferring one.

    THE PERIOD END IS NOT ALWAYS A SUNDAY. Four documents (07, 14, 21 and
    28 Nov 2025) print a Friday under a heading reading "Ending Sunday". The
    date is taken as printed and the fact is recorded in provenance, because
    it is a question for a person, not an error to correct here.

    CODES ARE NOT A TIDY PATTERN. Paul An's code is "AN - P" - two letters
    and spaces. Meera Thomas is "THOM_M" with an underscore on one sheet of
    her 44. A pattern assuming three to five letters and a hyphen drops Paul
    from all 21 of his weeks in silence; that happened, and was caught only
    because a human knew he had been paid. Codes are normalised, and

    EVERY ROW MUST PARSE. Any line carrying an employment class and a number
    is a data row. If one of them yields no usable code, the whole document
    is rejected. A parser that quietly matches a subset is indistinguishable
    from one that works.

    COLUMNS MOVE. Header positions differ between documents, and the later
    template labels both the Normal and the Total column "Hours". Anchors are
    read from each document's own header, and each number is assigned to the
    nearest anchor by its right edge, because the figures are right-aligned
    and blank columns collapse in the text layout.

    ADJUSTMENTS CAN BE NEGATIVE. Paul An, week ending 17 May 2026: -0.87,
    noted "-1.37 leaving early +0.5 break". A number pattern that does not
    accept a leading minus turns a deduction into an addition.

    THE SUM IS NOT GUARANTEED. 532 of 535 rows satisfy
    normal + overtime + adjustment = total. Three do not, and they are the
    documents' own arithmetic. They are staged with a note rather than
    refused; the registry carries line_total_does_not_sum as a warning.

THE TWO NOTES, per RULE-STG
    The Notes column printed on the document is producer content and is
    carried as payload.document_note. payload.notes belongs to whoever
    verifies and is never written here.
"""

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

from staging_envelope import (
    PRODUCED_BY, SCHEMA_VERSION, batch_id_for, envelope, write_batch,
)

INSTRUCTION = "payroll_instruction"
LINE = "payroll_instruction_line"

FILENAME_RE = re.compile(
    r"Payroll - My Little Friend - 115KWS - (\d{4})_(\d{2})_(\d{2})\.pdf$")

# Both section vocabularies. Anything else stops the document.
SECTIONS = {
    "115connect": "115connect",
    "admin - building management": "115connect",
    "cafe": "Cafe",
    "café": "Cafe",
    "farm": "Farm",
    "gardener": "Farm",
}

CLASS_MAP = {"C": "Casual", "Casual": "Casual",
             "Part Time": "Part Time", "Full Time": "Full Time"}

CLASS_RE = re.compile(r"\s(C|Casual|Part Time|Full Time)(\s{2,}|$)")
NUM_RE = re.compile(r"(?<![\w./])(-?\d+(?:\.\d+)?)(?![\w./-])")
PERIOD_RE = re.compile(
    r"Pay Period Ending\s*\w*\s*:?\s+([0-9]{1,2}[/-][A-Za-z0-9]{1,4}[/-][0-9]{2,4})")
DATE_FORMATS = ("%d/%m/%Y", "%d-%b-%y", "%d/%m/%y", "%d-%b-%Y")

# Headings and totals that must never be read as a person.
SKIP_PREFIXES = ("employee", "employees", "total", "weekly pay period")


class DocumentRejected(Exception):
    """One bad document stops that document, never the batch silently."""


def normalise_code(raw):
    """Whitespace and underscores are typing, not identity."""
    return re.sub(r"\s+", "", raw).replace("_", "-").upper()


def pdf_lines(path):
    out = subprocess.run(["pdftotext", "-layout", path, "-"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise DocumentRejected("pdftotext failed: %s" % out.stderr.strip())
    return out.stdout.splitlines()


def parse_date(raw):
    for fmt in DATE_FORMATS:
        try:
            return dt.datetime.strptime(raw, fmt).date()
        except ValueError:
            continue
    raise DocumentRejected("cannot read the period end date %r" % raw)


def period_end_of(lines, path):
    """From the document body, cross-checked against the filename."""
    m = FILENAME_RE.search(os.path.basename(path))
    if not m:
        raise DocumentRejected("filename is not in the expected form")
    from_name = dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))

    found = None
    for ln in lines:
        pm = PERIOD_RE.search(ln)
        if pm:
            found = parse_date(pm.group(1))
            break
    if found is None:
        raise DocumentRejected("no 'Pay Period Ending' line in the document")

    if found != from_name:
        raise DocumentRejected(
            "the document says %s and the filename says %s. They agree in "
            "every document in the archive, so a disagreement means a rename "
            "or a re-issue - resolve it rather than letting one win."
            % (found, from_name))
    return found


def column_anchors(lines):
    """Right-hand edges of Normal, Overtime, Adjustment, Total, and the left
    edge of Notes, from this document's own header."""
    hi = next((i for i, l in enumerate(lines)
               if "Overtime" in l and "Adjustment" in l), None)
    if hi is None:
        raise DocumentRejected("no column header row")
    head = lines[hi]
    context = lines[max(0, hi - 2):hi + 3]
    hours = [m.end() for c in context
             for m in re.finditer(r"\bHours\b|\bHrs\b", c)]

    ot = head.find("Overtime")
    adj = head.find("Adjustment")
    tot = head.find("Total")
    notes = head.find("Notes")

    before = [x for x in hours if x <= ot]
    normal = max(before) if before else None
    if tot >= 0:
        total = tot + len("Total")
    else:
        after = [x for x in hours if x > adj + len("Adjustment")]
        total = min(after) if after else None
    if normal is None or total is None:
        raise DocumentRejected(
            "could not locate the Normal and Total columns in the header")
    return (normal, ot + len("Overtime"), adj + len("Adjustment"), total,
            notes if notes >= 0 else 10 ** 6)


def split_numbers(line, cls_end, cols, notes_x):
    """Assign each number to the nearest column by its right edge. The figures
    are right-aligned and a blank column collapses entirely, so position is
    the only thing that distinguishes an adjustment from a total."""
    slot = {}
    for m in NUM_RE.finditer(line):
        if m.start() < cls_end or m.end() > notes_x:
            continue
        j = min(range(4), key=lambda i: abs(cols[i] - m.end()))
        if j in slot:
            raise DocumentRejected(
                "two figures fall in the same column on: %s" % line.strip()[:60])
        slot[j] = float(m.group(1))
    return [slot.get(i, 0.0) for i in range(4)]


def parse_document(path):
    """-> (period_end, {business_unit: [line dict, ...]})"""
    lines = pdf_lines(path)
    period_end = period_end_of(lines, path)
    cols_all = column_anchors(lines)
    cols, notes_x = cols_all[:4], cols_all[4]

    units = {}
    unit = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped:
            continue
        low = stripped.lower()

        if low in SECTIONS:
            unit = SECTIONS[low]
            units.setdefault(unit, [])
            continue

        cm = CLASS_RE.search(stripped)
        looks_like_row = bool(cm) and bool(re.search(r"\d", stripped)) \
            and not low.startswith(SKIP_PREFIXES)
        if not looks_like_row:
            continue

        if unit is None:
            raise DocumentRejected(
                "a data row appears before any section heading this parser "
                "knows: %s" % stripped[:60])

        head = [t.strip() for t in re.split(r"\s{2,}", stripped[:cm.start()])
                if t.strip()]
        if len(head) < 2:
            raise DocumentRejected("cannot read the code and name from: %s"
                                   % stripped[:60])
        code = normalise_code(head[0])
        if not re.fullmatch(r"[A-Z][A-Z-]*-[A-Z]", code):
            raise DocumentRejected("unreadable employee code %r on: %s"
                                   % (head[0], stripped[:60]))

        if len(head) > 2:
            surname, first_name = head[1], head[2]
        else:
            words = head[1].split()
            surname = " ".join(words[:-1]) if len(words) > 1 else head[1]
            first_name = words[-1] if len(words) > 1 else ""

        offset = len(raw) - len(raw.lstrip())
        cls_end = offset + cm.start() + len(cm.group(1)) + 1
        normal, overtime, adjustment, total = split_numbers(
            raw, cls_end, cols, notes_x)

        note = raw[notes_x:].strip() if notes_x < len(raw) else ""

        units[unit].append({
            "employee_code": code,
            "surname": surname,
            "first_name": first_name,
            "employment_class": CLASS_MAP.get(cm.group(1), cm.group(1)),
            "normal_hours": round(normal, 2),
            "overtime_hours": round(overtime, 2),
            "adjustment_hours": round(adjustment, 2),
            "total_hours": round(total, 2),
            "document_note": note or None,
        })

    if not units:
        raise DocumentRejected("no sections found")
    return period_end, units


def provenance_for(path, period_end, notes):
    return {
        "source_document": os.path.basename(path),
        "source_workbook": os.path.abspath(path),
        "party_name": None,
        "notes": notes,
    }


def build(paths, produced_at, stamp):
    parents, children, report, rejected = [], [], [], []
    for path in paths:
        try:
            period_end, units = parse_document(path)
        except DocumentRejected as exc:
            rejected.append((os.path.basename(path), str(exc)))
            continue

        pe = period_end.isoformat()
        sunday = period_end.isoweekday() == 7
        for unit in sorted(units):
            rows = units[unit]
            if not rows:
                continue
            total = round(sum(r["total_hours"] for r in rows), 2)
            unsummed = [r["employee_code"] for r in rows
                        if abs(r["normal_hours"] + r["overtime_hours"]
                               + r["adjustment_hours"] - r["total_hours"]) > 0.005]

            notes = ["Pay instruction to Integrated Payroll Solutions."]
            if not sunday:
                notes.append(
                    "The period end printed on the document is a %s, not a "
                    "Sunday, under a heading reading 'Ending Sunday'. Taken "
                    "as printed." % period_end.strftime("%A"))
            if unsummed:
                notes.append(
                    "Normal + overtime + adjustment does not equal the "
                    "printed total for: %s. The document's own arithmetic, "
                    "staged as printed." % ", ".join(unsummed))

            parent = envelope(
                INSTRUCTION,
                {"period_end": pe, "business_unit": unit},
                {"total_hours": total, "staff_count": len(rows), "notes": None},
                provenance_for(path, period_end, " ".join(notes)),
                produced_at, batch_id_for(INSTRUCTION, stamp))
            parents.append(parent)

            for seq, r in enumerate(rows, start=1):
                children.append(envelope(
                    LINE,
                    {"period_end": pe, "business_unit": unit,
                     "employee_code": r["employee_code"], "seq": seq},
                    {"surname": r["surname"],
                     "first_name": r["first_name"],
                     "normal_hours": r["normal_hours"],
                     "overtime_hours": r["overtime_hours"],
                     "adjustment_hours": r["adjustment_hours"],
                     "total_hours": r["total_hours"],
                     "document_note": r["document_note"],
                     "notes": None},
                    provenance_for(path, period_end,
                                   "Line %d of the %s section." % (seq, unit)),
                    produced_at, batch_id_for(LINE, stamp),
                    parent_uid=parent["record_uid"], seq=seq))

            report.append((pe, unit, len(rows), total, sunday, len(unsummed)))
    return parents, children, report, rejected


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pdf-dir", default=os.environ.get("VERIFIER_PAYROLL_PDF_DIR"))
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--week", help="one period end, YYYY-MM-DD")
    ap.add_argument("--since", help="period ends on or after YYYY-MM-DD")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not shutil.which("pdftotext"):
        sys.exit("ERROR: pdftotext is not installed. It is part of poppler:\n"
                 "    brew install poppler\n"
                 "This producer reads column positions from the laid-out text, "
                 "so no other extractor is interchangeable with it.")
    if not args.pdf_dir:
        sys.exit("ERROR: no PDF folder. Set VERIFIER_PAYROLL_PDF_DIR or pass "
                 "--pdf-dir.")
    if not args.inbox and not args.dry_run:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")

    paths = sorted(glob.glob(os.path.join(
        args.pdf_dir, "Payroll - My Little Friend - 115KWS - *.pdf")))
    if args.week:
        want = args.week.replace("-", "_")
        paths = [p for p in paths if want in os.path.basename(p)]
    if args.since:
        since = args.since.replace("-", "_")
        paths = [p for p in paths
                 if os.path.basename(p)[-14:-4] >= since]
    if not paths:
        sys.exit("ERROR: no payroll documents matched in %s" % args.pdf_dir)

    produced_at = dt.datetime.now(dt.timezone.utc).isoformat()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    parents, children, report, rejected = build(paths, produced_at, stamp)

    print("payroll instructions from %d document(s) in %s\n"
          % (len(paths), args.pdf_dir))
    print("   %-12s %-11s %5s %10s  %s" % ("PERIOD END", "UNIT", "STAFF",
                                           "HOURS", "FLAGS"))
    for pe, unit, n, total, sunday, unsummed in report:
        flags = []
        if not sunday:
            flags.append("period end not Sunday")
        if unsummed:
            flags.append("%d line(s) do not sum" % unsummed)
        print("   %-12s %-11s %5d %10.2f  %s"
              % (pe, unit, n, total, "; ".join(flags)))

    print("\n   %d instruction(s), %d line(s)" % (len(parents), len(children)))

    if rejected:
        print("\nREJECTED - nothing from these documents was staged:")
        for name, why in rejected:
            print("   %s\n      %s" % (name, why))

    if not parents:
        print("\nNothing to stage.")
        return 1 if rejected else 0

    if args.dry_run:
        print("\nDry run. Nothing written.")
        return 1 if rejected else 0

    for rtype, records in ((INSTRUCTION, parents), (LINE, children)):
        if not records:
            continue
        name, manifest = write_batch(
            args.inbox, batch_id_for(rtype, stamp), rtype, records,
            produced_at, args.pdf_dir, False)
        print("\n   wrote %-28s %4d record(s)  sha256 %s"
              % (name, manifest["row_count"], manifest["sha256"][:16]))

    return 1 if rejected else 0


if __name__ == "__main__":
    sys.exit(main())
