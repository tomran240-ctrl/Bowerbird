"""
stage_records.py - turn records into a compliant staging batch.

    python3 stage_records.py --in records.json
    python3 stage_records.py --in records.json --dry-run

For a producer task that has the facts and the reasoning but should not be
hand-computing hashes. You supply natural keys, payloads and provenance; this
writes RULE-STG envelopes, manifests and file names.

WHY THIS EXISTS RATHER THAN THE TASK WRITING JSONL ITSELF
    record_uid is the only thing standing between a re-offered row and a
    duplicate:

        record_uid = sha256(record_type + "|" + canonical_json(natural_key))

    Canonical means sorted keys and no whitespace. Get one byte of that wrong
    and the guarantee is gone for that feed - silently, because a wrong uid
    looks exactly like a new record. Computing it in one tested place, rather
    than in a prompt every week, is the whole point of this script.

    You never supply a uid. You never supply a parent_uid either: give a child
    its parent's NATURAL KEY and the link is derived, so a parent and child
    cannot disagree about what they are linked to.

INPUT
    One JSON object:

    {
      "produced_by": "weekly-inbox-filing-review",
      "batches": [
        {
          "record_type": "cafe_invoice",
          "records": [
            {"natural_key": {"filename": "..."},
             "payload":     {"invoice_number": "...", ...},
             "provenance":  {"source_document": "...",
                             "source_workbook": null,
                             "party_name": "Forest Foods",
                             "notes": "Card surcharge billed on its own "
                                      "invoice, per RULE-AL."}}
          ]
        },
        {
          "record_type": "cafe_line",
          "parent_type": "cafe_invoice",
          "records": [
            {"parent_natural_key": {"filename": "..."},
             "seq": 1,
             "natural_key": {"filename": "...", "seq": 1},
             "payload":     {...},
             "provenance":  {...}}
          ]
        }
      ]
    }

    Batches are written parents first, in the order given. A child batch names
    its parent_type; its parent may be in this same file or already staged.

WHAT IS CHECKED BEFORE ANYTHING IS WRITTEN
    Structure only - business correctness is the verifier's job and the
    registry's. But a batch that fails any of these is not written at all,
    because a half-written inbox is worse than an empty one:

      - every record has natural_key, payload and provenance, all objects
      - provenance carries all four keys, no more and no fewer
      - a child has seq, and its natural_key CONTAINS that seq - RULE-STG
        makes position part of identity, because a document may legitimately
        repeat a line
      - no record_uid appears twice in one batch
      - a child's parent_natural_key resolves to a record in its parent batch
        in this same file, unless --parent-already-staged is passed
      - no value anywhere is a float NaN or Infinity, which json would write
        as bare NaN and no parser would read back

WHAT IT DELIBERATELY DOES NOT DO
    It does not read the registry and it does not touch the database. The
    ingester validates payload shape against field_spec and refuses the batch
    with a reason on disk. Two checks of the same thing in two places drift
    apart; this one stays structural.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import sys

# One definition of the hash, shared with every other producer. Two that
# differed by a byte would compute two uids for one record, and the
# duplicate guard would fail silently for whichever feed used the wrong one.
from staging_envelope import canonical, record_uid

SCHEMA_VERSION = 1
PROVENANCE_KEYS = {"source_document", "source_workbook", "party_name", "notes"}


class Refused(Exception):
    pass


def bad_numbers(obj, where):
    """json.dumps writes NaN and Infinity as bare tokens that nothing reads
    back. A spreadsheet-derived figure is the usual source."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.extend(bad_numbers(v, "%s.%s" % (where, k)))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(bad_numbers(v, "%s[%d]" % (where, i)))
    elif isinstance(obj, float) and not math.isfinite(obj):
        out.append("%s is %r, which is not a number JSON can carry" % (where, obj))
    return out


def check_record(rec, idx, record_type, is_child):
    errs = []
    where = "%s record %d" % (record_type, idx + 1)

    for key in ("natural_key", "payload", "provenance"):
        if key not in rec:
            errs.append("%s: no %s" % (where, key))
        elif not isinstance(rec[key], dict):
            errs.append("%s: %s must be an object" % (where, key))
    if errs:
        return errs

    prov = set(rec["provenance"])
    if prov != PROVENANCE_KEYS:
        missing = sorted(PROVENANCE_KEYS - prov)
        extra = sorted(prov - PROVENANCE_KEYS)
        if missing:
            errs.append("%s: provenance is missing %s" % (where, ", ".join(missing)))
        if extra:
            errs.append("%s: provenance has unexpected key(s) %s"
                        % (where, ", ".join(extra)))

    if is_child:
        if rec.get("seq") is None:
            errs.append("%s: a child record needs seq" % where)
        elif rec["natural_key"].get("seq") != rec["seq"]:
            errs.append(
                "%s: seq is %r but natural_key.seq is %r. Position is part of "
                "identity - a document may legitimately repeat a line, and a "
                "key built from content alone drops the repeats."
                % (where, rec["seq"], rec["natural_key"].get("seq")))
        if not isinstance(rec.get("parent_natural_key"), dict):
            errs.append("%s: a child needs parent_natural_key (not a uid)" % where)

    for field in ("natural_key", "payload", "provenance"):
        if isinstance(rec.get(field), dict):
            errs.extend("%s: %s" % (where, m)
                        for m in bad_numbers(rec[field], field))
    return errs


def build(spec, stamp, produced_at):
    produced_by = spec.get("produced_by")
    if not produced_by:
        raise Refused(["no produced_by - the envelope has to name the task "
                       "that wrote it"])
    batches = spec.get("batches")
    if not isinstance(batches, list) or not batches:
        raise Refused(["no batches"])

    errs = []
    known_uids = {}
    out = []

    for b in batches:
        rt = b.get("record_type")
        if not rt:
            errs.append("a batch has no record_type")
            continue
        parent_type = b.get("parent_type")
        records = b.get("records") or []
        if not records:
            continue

        batch_id = "%s__%s__%s" % (produced_by, rt, stamp)
        seen = {}
        envelopes = []

        for i, rec in enumerate(records):
            problems = check_record(rec, i, rt, bool(parent_type))
            if problems:
                errs.extend(problems)
                continue

            uid = record_uid(rt, rec["natural_key"])
            if uid in seen:
                errs.append(
                    "%s record %d: the same natural key appears twice in this "
                    "batch, as record %d. %s"
                    % (rt, i + 1, seen[uid] + 1, canonical(rec["natural_key"])))
                continue
            seen[uid] = i

            parent_uid = None
            if parent_type:
                parent_uid = record_uid(parent_type, rec["parent_natural_key"])
                if (parent_uid not in known_uids
                        and not b.get("parent_already_staged")):
                    errs.append(
                        "%s record %d: its parent %s is not in this file. "
                        "Put the parent batch before this one, or set "
                        "parent_already_staged on this batch if it is already "
                        "in staging."
                        % (rt, i + 1, canonical(rec["parent_natural_key"])))
                    continue

            envelopes.append({
                "schema_version": SCHEMA_VERSION,
                "record_uid": uid,
                "batch_id": batch_id,
                "record_type": rt,
                "parent_uid": parent_uid,
                "seq": rec.get("seq"),
                "produced_by": produced_by,
                "produced_at": produced_at,
                "natural_key": rec["natural_key"],
                "payload": rec["payload"],
                "provenance": rec["provenance"],
            })

        known_uids.update(dict((u, rt) for u in seen))
        out.append((rt, batch_id, envelopes))

    if errs:
        raise Refused(errs)
    return out


def write_batch(inbox, batch_id, record_type, envelopes, produced_at,
                produced_by, source, dry_run):
    name = batch_id + ".jsonl"
    body = "".join(canonical(e) + "\n" for e in envelopes)
    manifest = {
        "batch_id": batch_id,
        "record_type": record_type,
        "produced_by": produced_by,
        "produced_at": produced_at,
        "schema_version": SCHEMA_VERSION,
        "source_file": name,
        "source_workbook": os.path.abspath(source) if source else None,
        "row_count": len(envelopes),
        "sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }
    if not dry_run:
        with open(os.path.join(inbox, name), "w", encoding="utf-8") as fh:
            fh.write(body)
        with open(os.path.join(inbox, batch_id + ".manifest.json"), "w",
                  encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
            fh.write("\n")
    return name, manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="infile", required=True,
                    help="the JSON file of records, or - for stdin")
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.inbox and not args.dry_run:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")

    raw = sys.stdin.read() if args.infile == "-" else open(
        args.infile, encoding="utf-8").read()
    try:
        spec = json.loads(raw)
    except ValueError as exc:
        sys.exit("ERROR: the input is not JSON: %s" % exc)

    produced_at = dt.datetime.now(dt.timezone.utc).isoformat()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    try:
        built = build(spec, stamp, produced_at)
    except Refused as exc:
        print("REFUSED - nothing was written:")
        for e in exc.args[0][:30]:
            print("   - %s" % e)
        if len(exc.args[0]) > 30:
            print("   ... and %d more" % (len(exc.args[0]) - 30))
        return 1

    total = sum(len(e) for _, _, e in built)
    if not total:
        print("Nothing to stage.")
        return 0

    source = None if args.infile == "-" else args.infile
    print("staging as %s\n" % spec["produced_by"])
    for rt, batch_id, envelopes in built:
        if not envelopes:
            continue
        name, manifest = write_batch(
            args.inbox or ".", batch_id, rt, envelopes, produced_at,
            spec["produced_by"], source, args.dry_run)
        print("   %-26s %4d record(s)  sha256 %s"
              % (rt, manifest["row_count"], manifest["sha256"][:16]))
        print("      %s" % name)

    if args.dry_run:
        print("\nDry run. Nothing written. %d record(s) would be staged."
              % total)
    else:
        print("\n%d record(s) written to %s" % (total, args.inbox))
        print("Now run staging_ingest.py, or press Refresh in the app.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
