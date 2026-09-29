"""
ingest_invoice_summary.py — manual CLI wrapper. Normally you won't need
this: the app now checks for and loads new rows from this file
automatically every time the home page loads. Kept for manual/offline use
(e.g. re-checking a batch without opening the app).

    python3 ingest_invoice_summary.py "path/to/Invoice Summary - Pending.xlsx"
"""
import os
import sys

import psycopg2

from ingest_lib import ingest_invoice_summary

DB_URL = os.environ.get("VERIFIER_DB_URL", "postgresql://verifier_app:testpass@127.0.0.1:5432/kws115_test")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print('Usage: python3 ingest_invoice_summary.py "path/to/Invoice Summary - Pending.xlsx"')
        sys.exit(1)
    conn = psycopg2.connect(DB_URL)
    try:
        stats = ingest_invoice_summary(conn, sys.argv[1])
    finally:
        conn.close()
    print(f"Ingested {stats['inserted']} café invoices"
          + (f" ({stats['skipped']} already present, skipped)" if stats['skipped'] else ""))
