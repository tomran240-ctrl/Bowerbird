"""
staging_ingest.py - the one way records enter staging.

Watches the Staging Inbox for envelope JSONL batches, validates each batch
against the staging.record_type registry, and loads it into staging.batch
and staging.record. A batch is all or nothing: it either lands whole and
moves to Processed, or nothing of it lands and it moves to Rejected with a
.error.txt saying exactly what was wrong.

    python3 staging_ingest.py --dry-run     validate and report, write and
                                            move nothing
    python3 staging_ingest.py               ingest for real

Environment:
    VERIFIER_DB_URL
    VERIFIER_STAGING_INBOX        default: alongside the workbooks
    VERIFIER_STAGING_PROCESSED    default: <inbox>/Processed
    VERIFIER_STAGING_REJECTED     default: <inbox>/Rejected

WHY A BATCH FAILS WHOLE RATHER THAN ROW BY ROW. A partial load leaves a
queue that looks complete and is not, and the missing rows are invisible
precisely because nothing is there to see. The cost of that shape is
already on the record here: an exact string comparison on a free text
column matched zero rows for three weeks, reported no error, and was found
only because someone went looking. Every check below therefore either
passes the whole batch or refuses it with a reason on disk.

WHAT IS NOT VALIDATED HERE. Business correctness is not this module's job.
A line that does not reconcile against its invoice header still loads - the
app surfaces that for a human, exactly as it does today. This module
refuses malformed, unknown or contradictory STRUCTURE, nothing more.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sys

SUPPORTED_SCHEMA_VERSIONS = (1,)
MAX_ERRORS_REPORTED = 50

ENVELOPE_KEYS = (
    "schema_version", "record_uid", "batch_id", "record_type",
    "produced_by", "produced_at", "natural_key", "payload",
)


class _AlreadyIngested(Exception):
    """Internal: this source_file already has a successful batch."""


class BatchRejected(Exception):
    def __init__(self, errors):
        self.errors = errors if isinstance(errors, list) else [errors]
        Exception.__init__(self, "; ".join(str(e) for e in self.errors[:3]))


def connect(db_url):
    import psycopg2
    return psycopg2.connect(db_url)


def load_registry(cur):
    cur.execute(
        "SELECT record_type, parent_type, field_spec, validation, active "
        "FROM staging.record_type"
    )
    registry = {}
    for record_type, parent_type, field_spec, validation, active in cur.fetchall():
        registry[record_type] = {
            "parent_type": parent_type,
            "field_spec": field_spec or {},
            "validation": validation or {},
            "active": active,
        }
    return registry


def depth_of(record_type, registry):
    """
    How many parents sit above this record type. Batches are ingested in
    ascending depth so a child never arrives before its parent, whatever
    the files happen to be called. Guards against a cycle in the registry
    rather than looping forever on one.
    """
    depth, seen, cursor = 0, set(), record_type
    while cursor is not None:
        if cursor in seen:
            raise BatchRejected("registry cycle at record_type '%s'" % cursor)
        seen.add(cursor)
        parent = registry.get(cursor, {}).get("parent_type")
        if parent is None:
            return depth
        depth += 1
        cursor = parent
    return depth


def discover(inbox):
    """Every .jsonl in the inbox, with the manifest beside it if present."""
    found = []
    for name in sorted(os.listdir(inbox)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(inbox, name)
        manifest = os.path.join(inbox, name[: -len(".jsonl")] + ".manifest.json")
        found.append((path, manifest if os.path.exists(manifest) else None))
    return found


def read_batch(jsonl_path, manifest_path):
    """
    Manifest integrity first, before a single line is interpreted. A
    truncated transfer is the one failure that can otherwise look exactly
    like a short batch.
    """
    errors = []
    with open(jsonl_path, "rb") as fh:
        raw = fh.read()
    body = raw.decode("utf-8")

    if manifest_path is None:
        raise BatchRejected("no .manifest.json beside %s" % os.path.basename(jsonl_path))
    with open(manifest_path, encoding="utf-8") as fh:
        try:
            manifest = json.load(fh)
        except ValueError as exc:
            raise BatchRejected("manifest is not valid JSON: %s" % exc)

    actual_sha = hashlib.sha256(raw).hexdigest()
    if manifest.get("sha256") and manifest["sha256"] != actual_sha:
        errors.append(
            "manifest sha256 %s does not match file %s - the file is "
            "truncated or was modified after it was written"
            % (manifest["sha256"], actual_sha)
        )

    records = []
    for n, line in enumerate(body.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except ValueError as exc:
            errors.append("line %d is not valid JSON: %s" % (n, exc))

    declared = manifest.get("row_count")
    if declared is not None and declared != len(records):
        errors.append(
            "manifest declares %s rows, file holds %d" % (declared, len(records))
        )

    if errors:
        raise BatchRejected(errors)
    return manifest, records


def validate_field(field, value, enums, where):
    """
    One field against its registry spec. Lifted out of validate_payload so the
    app's edit endpoint checks a typed cell exactly as ingestion checks it -
    one implementation, no second set of rules to drift.
    """
    errors = []
    name = field["name"]

    if value is None:
        if field.get("required"):
            errors.append("%s: required field '%s' is missing or null" % (where, name))
        return errors

    kind = field.get("type")
    if kind in ("money", "number"):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append("%s: field '%s' should be a number, got %r" % (where, name, value))
    elif kind == "boolean":
        if not isinstance(value, bool):
            errors.append("%s: field '%s' should be true or false, got %r" % (where, name, value))
    elif kind == "date":
        try:
            dt.date.fromisoformat(str(value))
        except ValueError:
            errors.append("%s: field '%s' should be an ISO date, got %r" % (where, name, value))
    elif kind in ("text", "longtext", "lookup"):
        # An NMI or an invoice number is a digit string, and pandas will hand
        # one over as a number given half a chance. Comparing 20022924634 to
        # '20022924634' in Postgres raises "operator does not exist: text =
        # bigint" at promotion time, long after anyone is watching, so it is
        # caught here instead.
        if not isinstance(value, str):
            errors.append("%s: field '%s' should be text, got %s %r"
                          % (where, name, type(value).__name__, value))
    elif kind == "enum":
        allowed = enums.get(name)
        if allowed is None:
            errors.append("%s: field '%s' is an enum with no allowed list in the registry" % (where, name))
        elif value not in allowed:
            errors.append(
                "%s: field '%s' is %r, which is not one of %s"
                % (where, name, value, ", ".join(repr(a) for a in allowed))
            )
    return errors


def validate_payload(payload, spec, where):
    errors = []
    fields = spec["field_spec"].get("fields", [])
    known = set(f["name"] for f in fields)
    enums = spec["validation"].get("enums", {})

    for extra in sorted(set(payload) - known):
        errors.append(
            "%s: unknown payload field '%s'. Add it to the record_type "
            "registry before producing it." % (where, extra)
        )

    for field in fields:
        errors.extend(validate_field(field, payload.get(field["name"]), enums, where))
    return errors


def canonical_uid(record_type, natural_key):
    canonical = json.dumps(natural_key, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256((record_type + "|" + canonical).encode("utf-8")).hexdigest()


def validate_batch(manifest, records, registry):
    errors = []
    record_type = manifest.get("record_type")
    batch_id = manifest.get("batch_id")

    if record_type not in registry:
        raise BatchRejected(
            "unknown record_type '%s'. Known types: %s"
            % (record_type, ", ".join(sorted(registry)) or "none")
        )
    spec = registry[record_type]
    if not spec["active"]:
        raise BatchRejected("record_type '%s' is registered but not active" % record_type)

    expected_keys = spec["field_spec"].get("natural_key", [])
    seen_uids = set()

    for n, rec in enumerate(records, start=1):
        where = "record %d" % n

        missing = [k for k in ENVELOPE_KEYS if k not in rec]
        if missing:
            errors.append("%s: envelope is missing %s" % (where, ", ".join(missing)))
            continue

        if rec["schema_version"] not in SUPPORTED_SCHEMA_VERSIONS:
            errors.append(
                "%s: schema_version %r is not supported by this ingester (supports %s)"
                % (where, rec["schema_version"],
                   ", ".join(str(v) for v in SUPPORTED_SCHEMA_VERSIONS))
            )
        if rec["record_type"] != record_type:
            errors.append(
                "%s: record_type '%s' does not match the batch's '%s'"
                % (where, rec["record_type"], record_type)
            )
        if rec["batch_id"] != batch_id:
            errors.append(
                "%s: batch_id '%s' does not match the manifest's '%s'"
                % (where, rec["batch_id"], batch_id)
            )

        natural_key = rec.get("natural_key")
        if not isinstance(natural_key, dict) or not natural_key:
            errors.append("%s: natural_key must be a non-empty object" % where)
        else:
            key_fields = sorted(natural_key)
            if expected_keys and key_fields != sorted(expected_keys):
                errors.append(
                    "%s: natural_key has fields %s, the registry expects %s"
                    % (where, key_fields, sorted(expected_keys))
                )
            else:
                expected_uid = canonical_uid(record_type, natural_key)
                if rec["record_uid"] != expected_uid:
                    errors.append(
                        "%s: record_uid does not match its natural_key. "
                        "Expected %s, got %s." % (where, expected_uid, rec["record_uid"])
                    )

        if rec["record_uid"] in seen_uids:
            errors.append("%s: record_uid %s appears twice in this batch"
                          % (where, rec["record_uid"]))
        seen_uids.add(rec["record_uid"])

        payload = rec.get("payload")
        if not isinstance(payload, dict):
            errors.append("%s: payload must be an object" % where)
        else:
            errors.extend(validate_payload(payload, spec, where))

        if spec["parent_type"] is not None and not rec.get("parent_uid"):
            errors.append(
                "%s: record_type '%s' is a child of '%s' but carries no parent_uid"
                % (where, record_type, spec["parent_type"])
            )
        if spec["parent_type"] is None and rec.get("parent_uid"):
            errors.append("%s: record_type '%s' has no parent type but carries a parent_uid"
                          % (where, record_type))

        if len(errors) >= MAX_ERRORS_REPORTED:
            errors.append("... stopping after %d errors" % MAX_ERRORS_REPORTED)
            break

    if errors:
        raise BatchRejected(errors)
    return spec


def check_parents(cur, records, seen_this_run):
    """
    Every parent_uid must already exist, either in staging.record or in a
    batch ingested earlier in this same run. A missing parent is refused
    rather than skipped: skipping is how a line item quietly disappears.
    """
    wanted = set(r["parent_uid"] for r in records if r.get("parent_uid"))
    wanted -= seen_this_run
    if not wanted:
        return
    cur.execute(
        "SELECT record_uid FROM staging.record WHERE record_uid = ANY(%s)",
        (list(wanted),),
    )
    present = set(row[0] for row in cur.fetchall())
    missing = sorted(wanted - present)
    if missing:
        raise BatchRejected(
            ["parent record %s is not staged - ingest its parent batch first" % uid
             for uid in missing[:MAX_ERRORS_REPORTED]]
        )


def match_party(cur, party_name):
    """
    Same four tier match the cafe path already uses, against the same two
    tables, so the alias register keeps learning no matter which feed a
    counterparty arrives on.
    """
    cur.execute(
        "SELECT organisation_id FROM normalisation.supplier_aliases WHERE alias_text = %s",
        (party_name,),
    )
    row = cur.fetchone()
    if row:
        return row[0], "alias", None, None

    cur.execute(
        "SELECT id, name FROM contacts.organisations WHERE lower(name) = lower(%s)",
        (party_name,),
    )
    row = cur.fetchone()
    if row:
        return row[0], "exact", None, None

    cur.execute(
        "SELECT id, name, similarity(name, %s) AS score FROM contacts.organisations "
        "ORDER BY score DESC LIMIT 1",
        (party_name,),
    )
    row = cur.fetchone()
    if row and row[2] >= 0.35:
        return row[0], "fuzzy", round(row[2], 2), row[1]

    return None, "none", None, None


def classify_existing(cur, records):
    """
    For every record_uid in this batch that staging already holds, return
    (row_status, payload_is_identical).

    WHY THIS EXISTS. record_uid is derived from the natural key alone, on
    purpose, so that a producer re-offering an unchanged row is a no-op. The
    cost of that guarantee is that the uid answers "have I seen this record?"
    and nothing answers "is the version I hold the current one?". A record
    whose payload was wrong and has since been corrected looks exactly like a
    duplicate.

    On 22 Sep 2026 sixteen Square hours records were re-emitted in decimal
    hours after being staged in minutes. Every one hit ON CONFLICT DO NOTHING,
    was counted as a duplicate, and the batch was marked ingested. The
    corrected figures were discarded and the run reported success.

    jsonb does the comparison rather than Python, so key order and numeric
    form are normalised and 28.0 is not different from 28.00. Provenance is
    deliberately NOT compared: it is producer metadata and shifts between runs
    without any verified fact changing.
    """
    if not records:
        return {}
    uids = [r["record_uid"] for r in records]
    payloads = [json.dumps(r["payload"]) for r in records]
    cur.execute(
        "SELECT r.record_uid, r.row_status, (r.payload = v.payload) AS same "
        "FROM staging.record r "
        "JOIN unnest(%s::text[], %s::jsonb[]) AS v(uid, payload) "
        "  ON v.uid = r.record_uid",
        (uids, payloads),
    )
    return dict((row[0], (row[1], row[2])) for row in cur.fetchall())


def ingest_batch(conn, manifest, records, spec, source_name, ingested_by, seen_this_run):
    party_field = spec["field_spec"].get("party_field")
    inserted = duplicates = amended = 0

    with conn.cursor() as cur:
        check_parents(cur, records, seen_this_run)

        cur.execute(
            "SELECT batch_id, status FROM staging.batch WHERE source_file = %s",
            (source_name,),
        )
        prior = cur.fetchone()
        if prior and prior[1] == "ingested":
            return {"skipped_already_ingested": True, "batch_id": prior[0],
                    "inserted": 0, "duplicates": len(records), "amended": 0}
        if prior and prior[1] == "rejected":
            cur.execute("DELETE FROM staging.batch WHERE source_file = %s", (source_name,))

        cur.execute(
            "INSERT INTO staging.batch (batch_id, record_type, produced_by, produced_at, "
            "schema_version, source_file, manifest_checksum, declared_rows, ingested_rows, "
            "ingested_by, status) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'ingested')",
            (manifest["batch_id"], manifest["record_type"], manifest["produced_by"],
             manifest["produced_at"], manifest.get("schema_version", 1), source_name,
             manifest.get("sha256"), manifest.get("row_count"), 0, ingested_by),
        )

        existing = classify_existing(cur, records)

        """A record the producer now disagrees with, that a person has already
        verified or imported, is not something to revise underneath them. The
        whole batch stops and names it; removing it is then a deliberate act."""
        conflicts = []
        for rec in records:
            prior = existing.get(rec["record_uid"])
            if prior and not prior[1] and prior[0] != "pending":
                conflicts.append(
                    "%s is already %s and the producer now sends different "
                    "figures for it. Nothing was loaded. Remove that record "
                    "deliberately if the new version is the right one."
                    % (json.dumps(rec["natural_key"], sort_keys=True), prior[0]))
        if conflicts:
            raise BatchRejected(conflicts[:MAX_ERRORS_REPORTED])

        for rec in records:
            uid = rec["record_uid"]
            provenance = rec.get("provenance") or {}
            party_name = provenance.get("party_name") if party_field else None
            party_id = match_type = match_score = candidate = None
            if party_name:
                party_id, match_type, match_score, candidate = match_party(cur, party_name)

            prior = existing.get(uid)
            if prior and prior[1]:
                duplicates += 1
                seen_this_run.add(uid)
                continue

            if prior:
                cur.execute(
                    "UPDATE staging.record SET batch_id = %s, parent_uid = %s, seq = %s, "
                    "payload = %s, provenance = %s, party_name = %s, party_id = %s, "
                    "match_type = %s, match_score = %s, candidate_name = %s "
                    "WHERE record_uid = %s AND row_status = 'pending'",
                    (manifest["batch_id"], rec.get("parent_uid"), rec.get("seq"),
                     json.dumps(rec["payload"]), json.dumps(provenance), party_name,
                     party_id, match_type, match_score, candidate, uid),
                )
                amended += cur.rowcount
                seen_this_run.add(uid)
                continue

            cur.execute(
                "INSERT INTO staging.record (record_uid, batch_id, record_type, parent_uid, "
                "seq, natural_key, payload, provenance, party_name, party_id, match_type, "
                "match_score, candidate_name) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
                "ON CONFLICT (record_uid) DO NOTHING",
                (uid, manifest["batch_id"], manifest["record_type"],
                 rec.get("parent_uid"), rec.get("seq"),
                 json.dumps(rec["natural_key"]), json.dumps(rec["payload"]),
                 json.dumps(provenance), party_name, party_id, match_type,
                 match_score, candidate),
            )
            if cur.rowcount == 1:
                inserted += 1
            else:
                duplicates += 1
            seen_this_run.add(uid)

        cur.execute(
            "UPDATE staging.batch SET ingested_rows = %s WHERE batch_id = %s",
            (inserted, manifest["batch_id"]),
        )

    return {"skipped_already_ingested": False, "batch_id": manifest["batch_id"],
            "inserted": inserted, "duplicates": duplicates, "amended": amended}


def reject(conn, source_name, manifest, errors, jsonl_path, manifest_path, rejected_dir):
    """A rejected batch leaves two traces: a row, and the file with its reason."""
    already_ingested = None
    if conn is not None and manifest:
        try:
            with conn.cursor() as cur:
                # NEVER delete a batch that landed. staging.record.batch_id is
                # ON DELETE CASCADE, so an unscoped delete here would take every
                # record that batch loaded with it - including rows already
                # verified by a human and rows already promoted to production.
                # A rejected file whose name matches a successful batch is a
                # name collision, not a replacement: say so and record nothing.
                cur.execute(
                    "SELECT batch_id, status FROM staging.batch WHERE source_file = %s",
                    (source_name,),
                )
                prior = cur.fetchone()
                if prior and prior[1] == "ingested":
                    already_ingested = prior[0]
                    raise _AlreadyIngested()
                cur.execute(
                    "DELETE FROM staging.batch WHERE source_file = %s AND status = 'rejected'",
                    (source_name,),
                )
                cur.execute(
                    "INSERT INTO staging.batch (batch_id, record_type, produced_by, "
                    "produced_at, schema_version, source_file, manifest_checksum, "
                    "declared_rows, ingested_rows, status, reject_reason) "
                    "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,0,'rejected',%s)",
                    (manifest.get("batch_id", source_name), manifest.get("record_type"),
                     manifest.get("produced_by", "unknown"),
                     manifest.get("produced_at", dt.datetime.now(dt.timezone.utc).isoformat()),
                     manifest.get("schema_version", 1), source_name,
                     manifest.get("sha256"), manifest.get("row_count"),
                     "\n".join(errors)[:4000]),
                )
            conn.commit()
        except _AlreadyIngested:
            conn.rollback()
            print("  (a batch with this source_file already ingested as %s - the "
                  "rejection is recorded in the file only, nothing in the database "
                  "was touched)" % already_ingested)
        except Exception as exc:
            conn.rollback()
            print("  (could not record the rejection in staging.batch: %s)" % exc)

    os.makedirs(rejected_dir, exist_ok=True)
    for path in (jsonl_path, manifest_path):
        if path and os.path.exists(path):
            shutil.move(path, os.path.join(rejected_dir, os.path.basename(path)))
    with open(os.path.join(rejected_dir, source_name + ".error.txt"), "w", encoding="utf-8") as fh:
        fh.write("Batch rejected %s\n" % dt.datetime.now(dt.timezone.utc).isoformat())
        fh.write("Source file: %s\n\n" % source_name)
        for err in errors:
            fh.write("  - %s\n" % err)
        fh.write("\nNothing from this batch was loaded. Fix the producer, "
                 "re-emit the batch, and drop it in the inbox again.\n")
        if already_ingested:
            fh.write("\nNOTE: a batch with this same source_file was already "
                     "ingested successfully as %s. That batch and its records were "
                     "left untouched. Re-emit under a new file name.\n"
                     % already_ingested)


def run(conn, inbox, processed_dir, rejected_dir, ingested_by, dry_run):
    with conn.cursor() as cur:
        registry = load_registry(cur)
    if not registry:
        sys.exit("ERROR: staging.record_type is empty. Run migration 005 first.")

    batches = discover(inbox)
    if not batches:
        print("inbox empty: %s" % inbox)
        return 0

    def order(pair):
        name = os.path.basename(pair[0])
        manifest_path = pair[1]
        record_type = None
        if manifest_path:
            try:
                with open(manifest_path, encoding="utf-8") as fh:
                    record_type = json.load(fh).get("record_type")
            except (ValueError, OSError):
                record_type = None
        try:
            d = depth_of(record_type, registry) if record_type in registry else 99
        except BatchRejected:
            d = 99
        return (d, name)

    seen_this_run = set()
    totals = {"ingested": 0, "rejected": 0, "records": 0, "duplicates": 0,
              "amended": 0}

    for jsonl_path, manifest_path in sorted(batches, key=order):
        source_name = os.path.basename(jsonl_path)
        print("\n%s" % source_name)
        manifest = None
        try:
            manifest, records = read_batch(jsonl_path, manifest_path)
            spec = validate_batch(manifest, records, registry)
            if dry_run:
                with conn.cursor() as cur:
                    check_parents(cur, records, seen_this_run)
                    seen_this_run.update(r["record_uid"] for r in records)
                print("  would ingest: %d records, type %s"
                      % (len(records), manifest["record_type"]))
                totals["ingested"] += 1
                totals["records"] += len(records)
                continue

            result = ingest_batch(conn, manifest, records, spec, source_name,
                                  ingested_by, seen_this_run)
            conn.commit()

            if result["skipped_already_ingested"]:
                print("  already ingested as %s - moving to Processed, nothing loaded"
                      % result["batch_id"])
            else:
                note = ""
                if result["amended"]:
                    note = ", %d AMENDED - a staged record's figures were " \
                           "corrected by this batch" % result["amended"]
                print("  ingested %d records (%d unchanged and already staged%s)"
                      % (result["inserted"], result["duplicates"], note))
            totals["ingested"] += 1
            totals["records"] += result["inserted"]
            totals["duplicates"] += result["duplicates"]
            totals["amended"] += result["amended"]

            os.makedirs(processed_dir, exist_ok=True)
            for path in (jsonl_path, manifest_path):
                if path and os.path.exists(path):
                    shutil.move(path, os.path.join(processed_dir, os.path.basename(path)))

        except BatchRejected as exc:
            conn.rollback()
            print("  REJECTED - nothing loaded:")
            for err in exc.errors:
                print("    - %s" % err)
            totals["rejected"] += 1
            if not dry_run:
                reject(conn, source_name, manifest, exc.errors,
                       jsonl_path, manifest_path, rejected_dir)
        except Exception as exc:
            conn.rollback()
            print("  REJECTED - nothing loaded: %s" % exc)
            totals["rejected"] += 1
            if not dry_run:
                reject(conn, source_name, manifest, [str(exc)],
                       jsonl_path, manifest_path, rejected_dir)

    print("\n%s: %d batch(es) ok, %d rejected, %d records loaded, "
          "%d unchanged, %d amended"
          % ("DRY RUN" if dry_run else "done", totals["ingested"], totals["rejected"],
             totals["records"], totals["duplicates"], totals["amended"]))
    return 1 if totals["rejected"] else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inbox", default=os.environ.get("VERIFIER_STAGING_INBOX"))
    ap.add_argument("--processed", default=os.environ.get("VERIFIER_STAGING_PROCESSED"))
    ap.add_argument("--rejected", default=os.environ.get("VERIFIER_STAGING_REJECTED"))
    ap.add_argument("--db-url", default=os.environ.get("VERIFIER_DB_URL"))
    ap.add_argument("--by", default=os.environ.get("USER", "unknown"))
    ap.add_argument("--dry-run", action="store_true",
                    help="validate everything, write nothing, move nothing")
    args = ap.parse_args()

    if not args.inbox:
        sys.exit("ERROR: no inbox. Set VERIFIER_STAGING_INBOX or pass --inbox.")
    if not os.path.isdir(args.inbox):
        sys.exit("ERROR: inbox is not a directory: %s" % args.inbox)
    if not args.db_url:
        sys.exit("ERROR: no database. Set VERIFIER_DB_URL or pass --db-url.")

    processed = args.processed or os.path.join(args.inbox, "Processed")
    rejected = args.rejected or os.path.join(args.inbox, "Rejected")

    conn = connect(args.db_url)
    try:
        sys.exit(run(conn, args.inbox, processed, rejected, args.by, args.dry_run))
    finally:
        conn.close()


if __name__ == "__main__":
    main()
