"""
staging_reconcile.py - reconcile staging against production.

    python3 staging_reconcile.py                 report only
    python3 staging_reconcile.py --apply         mark them imported

Finds staged records whose production row already exists, and records that
fact. It marks them 'imported' rather than 'deleted', because that is what
actually happened: the invoice reached production, just not through this app.

WHY THIS IS NEEDED, AND WHY IT IS NOT A ONE-OFF
    A producer workbook is never cleared - it is shared with other processes -
    so it keeps offering the same rows for weeks. What stops an invoice being
    handled twice is the memory of having seen it: under the old cafe path a
    UNIQUE index on filename, under the envelope a record_uid that persists
    whatever the row's status.

    Two things break that memory. A record removed from staging entirely
    (staging_remove_batch) takes its record_uid with it, so the next run
    re-stages it. And work imported by a route that does not write to staging
    at all leaves no trace here - which is exactly what happened to eleven
    cafe invoices imported on 08 Sep 2026 while their staging rows sat in the
    queue as unfinished.

    This closes both: anything already in production is marked imported, gets
    its production id recorded, and stops appearing as work.

SAFETY
    - Reports by default. Nothing is written without --apply.
    - Matches on each record type's own production duplicate key - the same
      one promotion blocks on - never on an id.
    - Touches only records in 'pending' or 'verified'. Never reopens or
      alters anything already imported, deleted or rejected.
    - Writes nothing to production. It only annotates staging.
"""

import argparse
import datetime as dt
import os
import sys

from promote import PROMOTERS


def connect(db_url):
    import psycopg2
    import psycopg2.extras
    return psycopg2.connect(db_url, cursor_factory=psycopg2.extras.RealDictCursor)


def id_query(dup_sql):
    """
    Promotion only asks whether a duplicate exists; here we also want the
    production id, so the row can point at what superseded it. Every dup_sql
    is written as "SELECT 1 FROM ...", which makes this rewrite safe - and
    asserted rather than assumed, so a future promoter that breaks the shape
    fails loudly here instead of silently matching nothing.
    """
    prefix = "SELECT 1 "
    if not dup_sql.startswith(prefix):
        raise SystemExit("ERROR: dup_sql does not start with 'SELECT 1 ': %s" % dup_sql)
    return "SELECT id " + dup_sql[len(prefix):]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--type", dest="only_type", default=None)
    ap.add_argument("--apply", action="store_true", help="write the changes")
    ap.add_argument("--db-url", default=os.environ.get("VERIFIER_DB_URL"))
    args = ap.parse_args()
    if not args.db_url:
        sys.exit("ERROR: no database. Set VERIFIER_DB_URL or pass --db-url.")

    conn = connect(args.db_url)
    found = []
    try:
        with conn.cursor() as cur:
            types = [args.only_type] if args.only_type else sorted(PROMOTERS)
            for rt in types:
                p = PROMOTERS.get(rt)
                if p is None:
                    sys.exit("ERROR: no promoter for '%s'" % rt)
                sql = id_query(p["dup_sql"])

                cur.execute(
                    "SELECT record_uid, record_type, natural_key, payload, "
                    "party_name, party_id, row_status FROM staging.record "
                    "WHERE record_type = %s AND parent_uid IS NULL "
                    "  AND row_status IN ('pending','verified') "
                    "ORDER BY created_at, record_uid",
                    (rt,),
                )
                for rec in [dict(r) for r in cur.fetchall()]:
                    cur.execute(sql, p["dup_keys"](rec))
                    hit = cur.fetchone()
                    if hit:
                        found.append({"rec": rec, "type": rt,
                                      "prod_id": hit["id"],
                                      "target": "%s.%s" % p["target"],
                                      "label": p["dup_label"](rec)})

        if not found:
            print("Nothing to reconcile: no staged record matches a production row.")
            return 0

        print("%d staged record(s) are already in production:\n" % len(found))
        for f in found:
            print("   %-22s %-46s -> %s id %s (currently %s)"
                  % (f["type"], f["label"][:46], f["target"], f["prod_id"],
                     f["rec"]["row_status"]))

        if not args.apply:
            print("\nReport only. Re-run with --apply to mark these imported.")
            return 0

        now = dt.datetime.now(dt.timezone.utc)
        marked = children = 0
        with conn.cursor() as cur:
            for f in found:
                uid = f["rec"]["record_uid"]
                cur.execute(
                    "UPDATE staging.record SET row_status = 'imported', "
                    "imported_at = %s, import_target = %s, import_pk = %s "
                    "WHERE record_uid = %s AND row_status IN ('pending','verified')",
                    (now, f["target"], str(f["prod_id"]), uid),
                )
                marked += cur.rowcount
                cur.execute(
                    "UPDATE staging.record SET row_status = 'imported', "
                    "imported_at = %s, import_target = %s, import_pk = %s "
                    "WHERE parent_uid = %s AND row_status IN ('pending','verified')",
                    (now, f["target"], str(f["prod_id"]), uid),
                )
                children += cur.rowcount
        conn.commit()
        print("\nMarked %d record(s) and %d child row(s) as imported."
              % (marked, children))
        print("They keep their record_uid, so the producer offering them again "
              "is now a no-op rather than new work.")
        return 0
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
