"""
staging_remove_batch.py - take a staged batch back out.

    python3 staging_remove_batch.py --list
    python3 staging_remove_batch.py --batch <batch_id> --dry-run
    python3 staging_remove_batch.py --batch <batch_id>

Staging a batch is easy and reversible; until now, un-staging it was neither.
This exists so a replay, a test, or a batch dropped in by mistake can be
removed without clicking Remove on every record.

staging.record.batch_id is ON DELETE CASCADE, so deleting the batch row takes
its records with it - and their children, via parent_uid, which also cascades.
That is exactly the power that made an unscoped DELETE in the ingester
dangerous, so this tool is deliberately narrow:

  - it removes ONE named batch at a time, never a pattern or a sweep
  - it REFUSES outright if any record in that batch has been imported into
    production. An imported record is the audit trail linking a production
    row back to the document it came from, and nothing here may destroy it
  - it names what it will remove and asks, unless --yes is given

If a batch holds imported records and you still want the rest gone, mark the
unimported ones deleted in the app instead. That keeps the history.
"""

import argparse
import os
import sys


def connect(db_url):
    import psycopg2
    import psycopg2.extras
    return psycopg2.connect(db_url, cursor_factory=psycopg2.extras.RealDictCursor)


def list_batches(cur):
    cur.execute(
        "SELECT b.batch_id, b.record_type, b.status, b.ingested_at, b.source_file, "
        "       count(r.record_uid) AS records, "
        "       count(*) FILTER (WHERE r.row_status = 'imported') AS imported "
        "FROM staging.batch b "
        "LEFT JOIN staging.record r ON r.batch_id = b.batch_id "
        "GROUP BY b.batch_id, b.record_type, b.status, b.ingested_at, b.source_file "
        "ORDER BY b.ingested_at DESC"
    )
    rows = cur.fetchall()
    # Never truncate the batch_id: it is the argument the caller has to copy,
    # and a clipped id is worse than a wide line.
    width = max([len(r["batch_id"]) for r in rows] + [len("batch_id")])
    fmt = "%-" + str(width) + "s  %-22s %8s %9s"
    print(fmt % ("batch_id", "record_type", "records", "imported"))
    for r in rows:
        print(fmt % (r["batch_id"], r["record_type"], r["records"], r["imported"]))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--batch", action="append", default=[],
                    help="batch_id to remove; repeatable")
    ap.add_argument("--list", action="store_true", help="show batches and exit")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation")
    ap.add_argument("--db-url", default=os.environ.get("VERIFIER_DB_URL"))
    args = ap.parse_args()

    if not args.db_url:
        sys.exit("ERROR: no database. Set VERIFIER_DB_URL or pass --db-url.")
    conn = connect(args.db_url)
    try:
        with conn.cursor() as cur:
            if args.list or not args.batch:
                list_batches(cur)
                if not args.batch:
                    print("\nNothing removed. Pass --batch <batch_id> to remove one.")
                return 0

            total_records = 0
            for batch_id in args.batch:
                cur.execute("SELECT record_type, source_file FROM staging.batch "
                            "WHERE batch_id = %s", (batch_id,))
                b = cur.fetchone()
                if b is None:
                    sys.exit("ERROR: no batch %s" % batch_id)

                cur.execute(
                    "SELECT count(*) AS n, "
                    "count(*) FILTER (WHERE row_status = 'imported') AS imported, "
                    "count(*) FILTER (WHERE row_status = 'verified') AS verified "
                    "FROM staging.record WHERE batch_id = %s", (batch_id,))
                c = cur.fetchone()

                if c["imported"]:
                    sys.exit(
                        "REFUSED: batch %s holds %d record(s) already imported into "
                        "production. Removing it would destroy the link between those "
                        "production rows and the documents they came from. Nothing was "
                        "removed." % (batch_id, c["imported"]))

                print("%s  (%s)" % (batch_id, b["record_type"]))
                print("    %d record(s), of which %d verified" % (c["n"], c["verified"]))
                total_records += c["n"]

            if args.dry_run:
                print("\nDRY RUN: %d batch(es) and %d record(s) would be removed."
                      % (len(args.batch), total_records))
                return 0

            if not args.yes:
                sys.stdout.write("\nRemove these permanently? [y/N] ")
                sys.stdout.flush()
                if sys.stdin.readline().strip().lower() not in ("y", "yes"):
                    print("Nothing removed.")
                    return 0

            for batch_id in args.batch:
                cur.execute("DELETE FROM staging.batch WHERE batch_id = %s", (batch_id,))
        conn.commit()
        print("\nRemoved %d batch(es) and %d record(s)."
              % (len(args.batch), total_records))
        return 0
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
