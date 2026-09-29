"""
ingest_cafe_line_items.py — manual CLI wrapper. Normally you won't need
this: the app now checks for and loads new rows from this file
automatically every time the home page loads. Kept for manual/offline use.

    python3 ingest_cafe_line_items.py "path/to/Cafe Line Items - Pending.xlsx"
"""
import os
import sys

import psycopg2

from ingest_lib import ingest_cafe_line_items

DB_URL = os.environ.get("VERIFIER_DB_URL", "postgresql://verifier_app:testpass@127.0.0.1:5432/kws115_test")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print('Usage: python3 ingest_cafe_line_items.py "path/to/Cafe Line Items - Pending.xlsx"')
        sys.exit(1)
    conn = psycopg2.connect(DB_URL)
    try:
        stats = ingest_cafe_line_items(conn, sys.argv[1])
    finally:
        conn.close()
    print(
        f"Ingested {stats['inserted']} line items"
        + (f" ({stats['skipped_dup']} duplicates skipped)" if stats['skipped_dup'] else "")
        + (f" ({stats['skipped_no_invoice']} skipped - no matching staged invoice)" if stats['skipped_no_invoice'] else "")
    )
