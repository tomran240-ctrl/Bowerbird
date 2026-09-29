"""
promote.py - move verified staging records into production.

    python3 promote.py --dry-run            check everything, write nothing
    python3 promote.py --type kw_invoice    promote one record type
    python3 promote.py                      promote every promotable type

A promotion is all or nothing. Every hard block is collected across the
whole run and reported together; if there is one, nothing at all is
written. This is deliberate: 107 building invoices and 206 meter bills are
already in production, so the expensive mistake here is a partial insert
that half-duplicates them.

WHICH COLUMNS GET WRITTEN IS DECIDED BY THE DESTINATION, NOT BY A LIST HERE.
The mapper reads the target table's real columns and writes the intersection
with the payload. Anything the payload carries that the table has no column
for is dropped and reported by name. That is how payment_status (no column
in accounting.invoices) and a tenancy bill's notes (no column in
individual_meter_bills) are handled - by the same rule, with no per-type
drop list to fall out of date. validation.dropped_on_promotion in the
registry documents the expected drops; it is not the mechanism.

A parent is promotable only when it is verified AND every one of its
non-deleted children is verified. Anything else is reported as not ready
and left alone.
"""

import argparse
import datetime as dt
import json
import os
import sys

from staging_ingest import validate_payload

def default_extras(rec, org):
    """Columns that cannot come from the payload: where the document is, and
    who the counterparty resolved to."""
    return {
        "source_file": (rec["provenance"] or {}).get("source_document"),
        "document_ref": (rec["natural_key"] or {}).get("filename"),
        "org_number": org["org_number"] if org else None,
    }


def cafe_extras(rec, org):
    return {
        "source_file": (rec["natural_key"] or {}).get("filename"),
        "supplier_id": rec["party_id"],
        "supplier_name": rec["party_name"],
        # cafe.invoices.notes has carried the producer's rationale for all 321
        # historical rows, so it keeps carrying it. The verifier's own note
        # lives in payload.notes and stays in staging - see "exclude" below.
        "notes": (rec["provenance"] or {}).get("notes"),
    }


def cafe_child_extras(rec, org):
    """cafe.purchases denormalises the supplier and invoice number onto every
    line, so each child needs values that only its parent holds."""
    return {
        "supplier_id": rec["party_id"],
        "supplier_name": rec["party_name"],
        "invoice_number": (rec["payload"] or {}).get("invoice_number"),
    }


def _mins(hours):
    """Hours back to the exact minute count the table stores.

    round(h * 60) cannot land on the wrong integer: h is within 0.005 h of the
    true value, so h * 60 is within 0.3 of the true minutes. The CHECK on the
    table verifies the reconstruction rather than trusting this note.
    """
    return None if hours is None else int(round(float(hours) * 60))


def payroll_instruction_extras(rec, org):
    nk = rec["natural_key"] or {}
    return {
        "period_end": nk.get("period_end"),
        "business_unit": nk.get("business_unit"),
        "source_document": (rec["provenance"] or {}).get("source_document"),
    }


def payroll_instruction_line_each(child, parent, org):
    """employee_code and seq live in the child's natural key, not its payload,
    so they cannot come from the parent the way cafe's supplier does."""
    nk = child["natural_key"] or {}
    return {"employee_code": nk.get("employee_code"), "seq": nk.get("seq")}


def payroll_hours_run_extras(rec, org):
    """The payload speaks decimal hours because that is what a person reads.
    The table stores integer minutes because clocked = rostered + adj_a + adj_b
    is exact in minutes and is not exact in hours rounded to two places. The
    hour keys are consumed here, not dropped - they are named with a null so
    the dropped-fields report does not cry loss over them."""
    pl = rec["payload"] or {}
    nk = rec["natural_key"] or {}
    return {
        "pay_week_start": nk.get("pay_week_start"),
        "rostered_minutes": _mins(pl.get("rostered_hours")),
        "adj_a_minutes": _mins(pl.get("adj_a_hours")),
        "adj_b_minutes": _mins(pl.get("adj_b_hours")),
        "clocked_minutes": _mins(pl.get("clocked_hours")),
        "rostered_hours": None, "adj_a_hours": None,
        "adj_b_hours": None, "clocked_hours": None,
    }


def payroll_hours_line_each(child, parent, org):
    pl = child["payload"] or {}
    nk = child["natural_key"] or {}
    return {
        "square_team_member_id": nk.get("square_team_member_id"),
        "seq": nk.get("seq"),
        "rostered_minutes": _mins(pl.get("rostered_hours")),
        "adj_a_minutes": _mins(pl.get("adj_a_hours")),
        "adj_b_minutes": _mins(pl.get("adj_b_hours")),
        "clocked_minutes": _mins(pl.get("clocked_hours")),
        "rostered_hours": None, "adj_a_hours": None,
        "adj_b_hours": None, "clocked_hours": None,
    }


# Per type: how to find a clash in production, and what cannot be derived
# from the payload alone.
PROMOTERS = {
    "cafe_invoice": {
        "target": ("cafe", "invoices"),
        # The legacy importer keyed on supplier AND number, because cafe
        # invoice numbers are only unique per supplier - two suppliers both
        # numbering from 1 is normal here.
        "dup_sql": "SELECT 1 FROM cafe.invoices "
                   "WHERE supplier_name = %s AND invoice_number = %s",
        "dup_keys": lambda rec: (rec["party_name"],
                                 (rec["payload"] or {}).get("invoice_number")),
        "dup_label": lambda rec: "%s / %s" % (
            rec["party_name"], (rec["payload"] or {}).get("invoice_number")),
        "constants": {"property_code": "115KW"},
        "needs_party": True,
        "children": {"cafe_line": ("cafe", "purchases")},
        "extras": cafe_extras,
        "exclude": {"notes"},
        "child_fk": "invoice_id",
        "child_constants": {"property_code": "115KW", "gst_status": "Auto"},
        "child_extras": cafe_child_extras,
    },
    "kw_invoice": {
        "target": ("accounting", "invoices"),
        "dup_sql": "SELECT 1 FROM accounting.invoices WHERE invoice_number = %s",
        "dup_keys": lambda rec: (rec["payload"].get("invoice_number"),),
        "dup_label": lambda rec: "invoice_number %s" % rec["payload"].get("invoice_number"),
        "constants": {"direction": "Inwards", "status": "reviewed"},
        "needs_party": True,
        "children": {},
    },
    "elec_main_bill": {
        "target": ("accounting", "main_meter_bills"),
        "dup_sql": "SELECT 1 FROM accounting.main_meter_bills "
                   "WHERE nmi = %s AND bill_period_start = %s AND bill_period_end = %s",
        "dup_keys": lambda rec: (rec["payload"].get("nmi"),
                                 rec["payload"].get("bill_period_start"),
                                 rec["payload"].get("bill_period_end")),
        "dup_label": lambda rec: "NMI %s for %s to %s" % (
            rec["payload"].get("nmi"), rec["payload"].get("bill_period_start"),
            rec["payload"].get("bill_period_end")),
        "constants": {},
        "needs_party": False,
        "children": {"elec_main_charge": ("accounting", "main_meter_bill_charges"),
                     "elec_main_other_charge": ("accounting", "main_meter_bill_other_charges")},
    },
    "elec_ind_bill": {
        "target": ("accounting", "individual_meter_bills"),
        "dup_sql": "SELECT 1 FROM accounting.individual_meter_bills "
                   "WHERE nmi = %s AND bill_period_start = %s AND bill_period_end = %s",
        "dup_keys": lambda rec: (rec["payload"].get("nmi"),
                                 rec["payload"].get("bill_period_start"),
                                 rec["payload"].get("bill_period_end")),
        "dup_label": lambda rec: "NMI %s for %s to %s" % (
            rec["payload"].get("nmi"), rec["payload"].get("bill_period_start"),
            rec["payload"].get("bill_period_end")),
        "constants": {},
        "needs_party": False,
        "children": {"elec_ind_charge": ("accounting", "individual_meter_bill_charges"),
                     "elec_ind_other_charge": ("accounting",
                                               "individual_meter_bill_other_charges")},
    },
    "payroll_instruction": {
        "target": ("payroll", "pay_instruction"),
        "dup_sql": "SELECT 1 FROM payroll.pay_instruction "
                   "WHERE period_end = %s AND business_unit = %s",
        "dup_keys": lambda rec: (rec["natural_key"].get("period_end"),
                                 rec["natural_key"].get("business_unit")),
        "dup_label": lambda rec: "%s week ending %s" % (
            rec["natural_key"].get("business_unit"),
            rec["natural_key"].get("period_end")),
        "constants": {},
        "needs_party": False,
        "extras": payroll_instruction_extras,
        # payload.notes is the verifier's own and goes to the table. The
        # producer's reasoning - a Friday period end, lines that do not sum -
        # stays in staging.provenance, which keeps the row forever.
        "children": {"payroll_instruction_line":
                     ("payroll", "pay_instruction_line")},
        "child_fk": "instruction_id",
        "child_extras_each": payroll_instruction_line_each,
    },
    "payroll_hours_run": {
        "target": ("payroll", "hours_run"),
        "dup_sql": "SELECT 1 FROM payroll.hours_run WHERE pay_week_start = %s",
        "dup_keys": lambda rec: (rec["natural_key"].get("pay_week_start"),),
        "dup_label": lambda rec: "pay week beginning %s" % (
            rec["natural_key"].get("pay_week_start")),
        "constants": {},
        "needs_party": False,
        "extras": payroll_hours_run_extras,
        "children": {"payroll_hours_line": ("payroll", "hours_line")},
        "child_fk": "run_id",
        "child_extras_each": payroll_hours_line_each,
    },
}



def connect(db_url):
    import psycopg2
    import psycopg2.extras
    return psycopg2.connect(db_url, cursor_factory=psycopg2.extras.RealDictCursor)


# information_schema is PRIVILEGE-FILTERED: it shows a role only the objects
# it holds some privilege on. Reading the destination's columns from it made a
# missing GRANT look like a missing table, and reported
# "destination accounting.invoices does not exist" about a table with 369 rows
# in it. pg_catalog is not filtered, so these read from there and privileges
# are checked separately and named for what they are.

def table_columns(cur, schema, table):
    cur.execute(
        "SELECT a.attname AS column_name "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = %s AND c.relname = %s "
        "  AND a.attnum > 0 AND NOT a.attisdropped "
        # A generated column cannot be written to: an INSERT naming one fails
        # with "cannot insert a non-DEFAULT value into column". hours_run and
        # hours_line each carry four, derived from their minutes.
        "  AND a.attgenerated = '' AND a.attidentity = ''",
        (schema, table),
    )
    return set(r["column_name"] for r in cur.fetchall())


def required_columns(cur, schema, table):
    """NOT NULL columns with no default. The registry cannot know these, and
    without the check a dry run reports 'no blocks found' for a row the real
    run will abort on."""
    cur.execute(
        "SELECT a.attname AS column_name "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum "
        "WHERE n.nspname = %s AND c.relname = %s "
        "  AND a.attnum > 0 AND NOT a.attisdropped "
        "  AND a.attnotnull AND d.adbin IS NULL",
        (schema, table),
    )
    return set(r["column_name"] for r in cur.fetchall())


def defaulted_not_null(cur, schema, table):
    """NOT NULL columns that DO have a default.

    These are the columns a payload must never name with a null. An explicit
    NULL overrides a default, it does not fall back to it, so a payload key
    carrying None for such a column turns something the database would have
    filled itself into a not-null violation at insert time.

    required_columns cannot see these and should not: the database can fill
    them. The fix belongs in build_row, which drops the key instead - the only
    safe reading of a null here, because writing one is certain to fail.

    Found by cafe.purchases.in_invoice_total (boolean NOT NULL DEFAULT true)
    aborting a promotion that had dry-run clean thirty seconds earlier. Same
    fault as migration 013 passing an explicit NULL over nav_tab_source.filter.
    """
    cur.execute(
        "SELECT a.attname AS column_name "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum "
        "WHERE n.nspname = %s AND c.relname = %s "
        "  AND a.attnum > 0 AND NOT a.attisdropped "
        "  AND a.attnotnull AND a.attgenerated = '' AND a.attidentity = ''",
        (schema, table),
    )
    return set(r["column_name"] for r in cur.fetchall())


def check_destination(cur, schema, table):
    """Distinguish absent from invisible, and say which grant is missing."""
    qualified = "%s.%s" % (schema, table)
    cur.execute("SELECT to_regclass(%s) IS NOT NULL AS present", (qualified,))
    if not cur.fetchone()["present"]:
        return "destination %s does not exist" % qualified
    cur.execute(
        "SELECT has_table_privilege(%s, 'SELECT') AS can_select, "
        "       has_table_privilege(%s, 'INSERT') AS can_insert",
        (qualified, qualified),
    )
    priv = cur.fetchone()
    missing = [n for n, ok in (("SELECT", priv["can_select"]),
                               ("INSERT", priv["can_insert"])) if not ok]
    if missing:
        return ("destination %s exists but this database role lacks %s on it. "
                "Run migration 009." % (qualified, " and ".join(missing)))
    return None


def spec_for(cur, record_type):
    cur.execute(
        "SELECT record_type, label, field_spec, validation FROM staging.record_type "
        "WHERE record_type = %s", (record_type,))
    row = cur.fetchone()
    return dict(row) if row else None


def candidates(cur, record_type, only_uid=None):
    cur.execute(
        "SELECT record_uid, record_type, natural_key, payload, provenance, party_id, "
        "party_name, match_type, row_status FROM staging.record "
        "WHERE record_type = %s AND row_status = 'verified' AND parent_uid IS NULL "
        "  AND (%s::text IS NULL OR record_uid = %s) "
        "ORDER BY created_at, record_uid",
        (record_type, only_uid, only_uid),
    )
    return [dict(r) for r in cur.fetchall()]


def children_of(cur, parent_uid):
    cur.execute(
        "SELECT record_uid, record_type, seq, natural_key, payload, provenance, row_status "
        "FROM staging.record WHERE parent_uid = %s AND row_status <> 'deleted' "
        "ORDER BY record_type, seq, record_uid",
        (parent_uid,),
    )
    return [dict(r) for r in cur.fetchall()]


def build_row(payload, columns, constants, extras, exclude=(),
              omit_if_none=()):
    row = dict((k, v) for k, v in (payload or {}).items()
               if k in columns and k not in exclude)
    row.update(dict((k, v) for k, v in constants.items() if k in columns))
    row.update(dict((k, v) for k, v in extras.items() if k in columns and v is not None))
    # A null for a NOT NULL column that carries a default is not a value,
    # it is a gap the database is willing to fill. Naming the column in the
    # INSERT at all stops it from filling it, so the key comes out.
    for dead in [k for k, v in row.items() if v is None and k in omit_if_none]:
        del row[dead]
    return row


def insert(cur, schema, table, row):
    cols = sorted(row)
    cur.execute(
        "INSERT INTO %s.%s (%s) VALUES (%s) RETURNING id"
        % (schema, table, ", ".join(cols), ", ".join(["%s"] * len(cols))),
        [row[c] for c in cols],
    )
    got = cur.fetchone()
    return got["id"] if got else None


def run(conn, only_type, dry_run, by, only_uid=None):
    blocks, plan, dropped_report = [], [], {}
    held_report = {}
    seen_keys = {}
    still_pending = {}

    with conn.cursor() as cur:
        types = [only_type] if only_type else list(PROMOTERS)
        for rt in types:
            if rt not in PROMOTERS:
                sys.exit("ERROR: no promoter for record type '%s'. Known: %s"
                         % (rt, ", ".join(sorted(PROMOTERS))))
            p = PROMOTERS[rt]
            spec = spec_for(cur, rt)
            if spec is None:
                sys.exit("ERROR: record type '%s' is not registered. Run migration 007."
                         % rt)
            problem = check_destination(cur, *p["target"])
            if problem:
                sys.exit("ERROR: %s" % problem)
            cols = table_columns(cur, *p["target"])

            cur.execute(
                "SELECT count(*) AS n FROM staging.record "
                "WHERE record_type = %s AND row_status = 'pending' AND parent_uid IS NULL",
                (rt,),
            )
            still_pending[rt] = cur.fetchone()["n"]

            for rec in candidates(cur, rt, only_uid):
                kids = children_of(cur, rec["record_uid"])
                unverified = [k for k in kids if k["row_status"] != "verified"]
                if unverified:
                    plan.append({"rec": rec, "type": rt, "skip":
                                 "%d child row(s) not verified" % len(unverified)})
                    continue

                where = "%s %s" % (spec["label"], p["dup_label"](rec))

                errs = validate_payload(rec["payload"] or {}, spec, where)
                blocks.extend(errs)

                if p["needs_party"] and not rec["party_id"]:
                    blocks.append("%s: no confirmed party. Pick one in the app first."
                                  % where)
                elif p["needs_party"] and rec["match_type"] not in ("alias", "exact"):
                    blocks.append("%s: supplier '%s' is not normalised (match: %s). "
                                  "Confirm it in the app first."
                                  % (where, rec["party_name"], rec["match_type"]))

                cur.execute(p["dup_sql"], p["dup_keys"](rec))
                if cur.fetchone():
                    blocks.append(
                        "%s: already in %s.%s. Nothing was written. Remove this record "
                        "in the app if it is a re-run of work already done."
                        % (where, p["target"][0], p["target"][1]))
                    continue

                org = None
                if p["needs_party"] and rec["party_id"]:
                    cur.execute("SELECT org_number FROM contacts.organisations WHERE id = %s",
                                (rec["party_id"],))
                    org = cur.fetchone()
                    if org is None:
                        blocks.append("%s: party_id %s is not in contacts.organisations"
                                      % (where, rec["party_id"]))

                extras = p.get("extras", default_extras)(rec, org)
                exclude = set(p.get("exclude", ()))
                child_fk = p.get("child_fk", "bill_id")

                payload_keys = set(rec["payload"] or {})
                # Two different things, and merging them once reported a
                # column that exists and is filled as a column that does
                # not exist. A real loss must never hide behind a
                # deliberate one.
                nowhere = sorted(payload_keys - cols - set(extras)
                                 - set(p["constants"]))
                if nowhere:
                    dropped_report.setdefault(rt, set()).update(nowhere)
                held = sorted(exclude & payload_keys)
                if held:
                    held_report.setdefault(rt, set()).update(held)

                # Two staged records that will write the same production key.
                # Checking each against production alone lets both through, and
                # the second then trips a unique constraint mid-write - atomic,
                # but reported as a traceback instead of a named block.
                dkey = (rt,) + tuple(p["dup_keys"](rec))
                if dkey in seen_keys:
                    blocks.append(
                        "%s: two staged records would write the same key. The other "
                        "is %s. Remove one in the app."
                        % (where, seen_keys[dkey][:12]))
                else:
                    seen_keys[dkey] = rec["record_uid"]

                omit = defaulted_not_null(cur, *p["target"])
                row_preview = build_row(rec["payload"], cols, p["constants"],
                                        extras, exclude, omit)
                missing_cols = sorted(
                    c for c in required_columns(cur, *p["target"])
                    if row_preview.get(c) is None)
                if missing_cols:
                    blocks.append(
                        "%s: destination %s.%s requires %s, which this record does "
                        "not supply." % (where, p["target"][0], p["target"][1],
                                         ", ".join(missing_cols)))

                child_rows = []
                for k in kids:
                    ct = p["children"].get(k["record_type"])
                    if ct is None:
                        blocks.append("%s: child type %s has no promoter"
                                      % (where, k["record_type"]))
                        continue
                    ccols = table_columns(cur, *ct)
                    cspec = spec_for(cur, k["record_type"])
                    blocks.extend(validate_payload(k["payload"] or {}, cspec,
                                                   "%s line %s" % (where, k["seq"])))
                    ceach = p.get("child_extras_each")
                    cex = dict(p.get("child_extras", lambda r, o: {})(rec, org))
                    if ceach:
                        cex.update(ceach(k, rec, org))
                    clost = sorted(set(k["payload"] or {}) - ccols - {"bill_id"}
                                   - set(cex))
                    if clost:
                        dropped_report.setdefault(k["record_type"], set()).update(clost)
                    comit = defaulted_not_null(cur, *ct)
                    cpreview = build_row(k["payload"], ccols,
                                         p.get("child_constants", {}), cex,
                                         set(p.get("child_exclude", ())), comit)
                    cmissing = sorted(c for c in required_columns(cur, *ct)
                                      if c != child_fk and cpreview.get(c) is None)
                    if cmissing:
                        blocks.append(
                            "%s line %s: destination %s.%s requires %s, which "
                            "this record does not supply."
                            % (where, k["seq"], ct[0], ct[1], ", ".join(cmissing)))
                    if child_fk not in ccols:
                        blocks.append("%s: %s.%s has no %s column to link "
                                      "children by" % (where, ct[0], ct[1], child_fk))
                    child_rows.append((k, ct, ccols, comit))

                plan.append({"rec": rec, "type": rt, "target": p["target"],
                             "cols": cols, "constants": p["constants"],
                             "extras": extras, "exclude": exclude,
                             "omit_if_none": omit,
                             "child_fk": child_fk,
                             "child_constants": p.get("child_constants", {}),
                             "child_exclude": set(p.get("child_exclude", ())),
                             "child_extras": p.get("child_extras",
                                                   lambda r, o: {})(rec, org),
                             "child_extras_each": p.get("child_extras_each"),
                             "org": org,
                             "children": child_rows})

    ready = [p for p in plan if "skip" not in p]
    skipped = [p for p in plan if "skip" in p]

    print("promotable records found : %d" % len(ready))
    print("not ready                : %d" % len(skipped))
    if sum(still_pending.values()):
        print("staged but not verified  : %d" % sum(still_pending.values()))
    for s in skipped:
        print("   %s - %s" % (s["rec"]["record_uid"][:12], s["skip"]))
    for rt, names in sorted(dropped_report.items()):
        print("dropped on promotion     : %s -> %s (no column in the destination)"
              % (rt, ", ".join(sorted(names))))
    for rt, names in sorted(held_report.items()):
        print("held in staging          : %s -> %s (kept out of production on purpose)"
              % (rt, ", ".join(sorted(names))))

    if blocks:
        print("\nBLOCKED - nothing was written. %d problem(s):" % len(blocks))
        for b in blocks:
            print("   - %s" % b)
        return 1

    if not ready:
        waiting = sum(still_pending.values())
        if waiting:
            # "Nothing to promote" on its own is a dead end when the records
            # are one tick away. Say where they actually are.
            print("\nNothing to promote. %d record(s) are staged but still "
                  "pending - promotion only ever considers records that have "
                  "been verified in the app:" % waiting)
            for rt, n in sorted(still_pending.items()):
                if n:
                    print("   %-22s %d pending" % (rt, n))
        else:
            print("\nNothing to promote.")
        return 0

    if dry_run:
        print("\nDRY RUN: %d record(s) would be promoted, no blocks found." % len(ready))
        for p in ready:
            print("   %s -> %s.%s%s" % (
                p["rec"]["record_uid"][:12], p["target"][0], p["target"][1],
                " (+%d children)" % len(p["children"]) if p["children"] else ""))
        return 0

    now = dt.datetime.now(dt.timezone.utc)
    written = child_written = 0
    with conn.cursor() as cur:
        for p in ready:
            rec = p["rec"]
            row = build_row(rec["payload"], p["cols"], p["constants"], p["extras"],
                            p["exclude"], p["omit_if_none"])
            new_id = insert(cur, p["target"][0], p["target"][1], row)
            written += 1

            for k, ct, ccols, comit in p["children"]:
                cextras = dict(p["child_extras"])
                if p.get("child_extras_each"):
                    cextras.update(p["child_extras_each"](k, rec, p["org"]))
                crow = build_row(k["payload"], ccols, p["child_constants"],
                                 cextras, p["child_exclude"], comit)
                crow[p["child_fk"]] = new_id
                insert(cur, ct[0], ct[1], crow)
                cur.execute(
                    "UPDATE staging.record SET row_status = 'imported', imported_at = %s, "
                    "import_target = %s, import_pk = %s WHERE record_uid = %s",
                    (now, "%s.%s" % ct, str(new_id), k["record_uid"]))
                child_written += 1

            cur.execute(
                "UPDATE staging.record SET row_status = 'imported', imported_at = %s, "
                "import_target = %s, import_pk = %s WHERE record_uid = %s",
                (now, "%s.%s" % p["target"], str(new_id), rec["record_uid"]))
    conn.commit()

    print("\npromoted %d record(s) and %d child row(s) by %s" % (written, child_written, by))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--type", dest="only_type", default=None)
    ap.add_argument("--db-url", default=os.environ.get("VERIFIER_DB_URL"))
    ap.add_argument("--by", default=os.environ.get("USER", "unknown"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only-uid", default=None,
                    help="promote just this verified parent record (and its lines)")
    args = ap.parse_args()
    if not args.db_url:
        sys.exit("ERROR: no database. Set VERIFIER_DB_URL or pass --db-url.")
    conn = connect(args.db_url)
    try:
        code = run(conn, args.only_type, args.dry_run, args.by, args.only_uid)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    sys.exit(code)


if __name__ == "__main__":
    main()
