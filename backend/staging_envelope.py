"""
staging_envelope.py - the RULE-STG envelope, in one place.

Every producer writes through these. record_uid in particular:

    record_uid = sha256(record_type + "|" + canonical_json(natural_key))

is the only thing standing between a re-offered row and a duplicate, and a
second implementation of it that differs by one byte would break the
guarantee silently for whichever feed used it. So there is one.

Extracted verbatim from shim_invoice_staging.py, which defined these and was
imported by every other producer - making a transitional workbook converter
load-bearing for payroll and electricity. Nothing here reads a spreadsheet;
see workbook_values.py for that.
"""

import hashlib
import json
import os

SCHEMA_VERSION = 1

PRODUCED_BY = "weekly-inbox-filing-review"

def canonical(obj):
    """Sorted keys, no whitespace. One definition, because two that drift by a
    byte would compute two different uids for one record."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def record_uid(record_type, natural_key):
    return hashlib.sha256(
        (record_type + "|" + canonical(natural_key)).encode("utf-8")).hexdigest()

def envelope(record_type, natural_key, payload, provenance,
             produced_at, batch_id, parent_uid=None, seq=None):
    return {
        "schema_version": SCHEMA_VERSION,
        "record_uid": record_uid(record_type, natural_key),
        "batch_id": batch_id,
        "record_type": record_type,
        "parent_uid": parent_uid,
        "seq": seq,
        "produced_by": PRODUCED_BY,
        "produced_at": produced_at,
        "natural_key": natural_key,
        "payload": payload,
        "provenance": provenance,
    }

def batch_id_for(record_type, stamp):
    return "{0}__{1}__{2}".format(PRODUCED_BY, record_type, stamp)

def write_batch(inbox, batch, record_type, records, produced_at, source_path, dry_run):
    name = batch + ".jsonl"
    body = "".join(
        json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n"
        for rec in records
    )
    manifest = {
        "batch_id": batch,
        "record_type": record_type,
        "produced_by": PRODUCED_BY,
        "produced_at": produced_at,
        "schema_version": SCHEMA_VERSION,
        "source_file": name,
        "source_workbook": os.path.abspath(source_path),
        "row_count": len(records),
        "sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    }
    if dry_run:
        return name, manifest
    with open(os.path.join(inbox, name), "w", encoding="utf-8") as fh:
        fh.write(body)
    with open(os.path.join(inbox, batch + ".manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return name, manifest
