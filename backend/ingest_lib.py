"""
ingest_lib.py — shared ingestion logic for both the manual CLI scripts and
the app's automatic on-refresh ingestion. One implementation, so the two
paths can never drift out of sync with each other.
"""
import pandas as pd

FUZZY_THRESHOLD = 0.35


# The source workbook is written by a task that types these two columns as
# free text, and it has not been consistent: the same column holds both
# "Inward" and "Inwards" across batches (and the current pending file uses
# "Inwards"). An exact-string filter silently matched zero rows rather than
# failing, so nothing was ingested and nothing said so. Compare on a
# normalised key instead, and keep the accepted spellings in one place.
CAFE_CATEGORIES = {"cafe", "caf\u00e9"}
INWARD_DIRECTIONS = {"inward", "inwards"}


def _norm_key(col):
    """Trimmed, lowercased comparison key for a free-text enum-ish column."""
    return col.astype(str).str.strip().str.lower()


def to_none(v):
    return None if pd.isna(v) else v


def to_bool(v):
    v = to_none(v)
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    # pandas upcasts a boolean column that also holds blank cells to float64,
    # so a cell containing TRUE arrives here as 1.0. str(1.0) is "1.0", which
    # did not match the "1" below, so an explicit TRUE silently became False -
    # inverting the meaning of in_invoice_total on the affected line. Compare
    # numerically first, and only fall back to text for genuine strings.
    if isinstance(v, (int, float)):
        return v != 0
    return str(v).strip().lower() in ("true", "yes", "1", "y", "t")


def match_supplier(cur, supplier_name: str):
    """
    Match tiers, in order:
      1. alias  - exact hit in normalisation.supplier_aliases               -> not flagged
      2. exact  - case-insensitive exact hit on contacts.organisations.name -> flagged
      3. fuzzy  - best trigram-similarity candidate (threshold 0.35)        -> flagged
      4. none   - nothing confident enough                                  -> flagged
    """
    cur.execute(
        "SELECT organisation_id FROM normalisation.supplier_aliases WHERE alias_text = %s",
        (supplier_name,),
    )
    row = cur.fetchone()
    if row:
        return row[0], "alias", None, None

    cur.execute(
        "SELECT id, name FROM contacts.organisations WHERE lower(name) = lower(%s)",
        (supplier_name,),
    )
    row = cur.fetchone()
    if row:
        return row[0], "exact", None, None

    cur.execute(
        """
        SELECT id, name, similarity(name, %s) AS score
        FROM contacts.organisations
        ORDER BY score DESC
        LIMIT 1
        """,
        (supplier_name,),
    )
    row = cur.fetchone()
    if row and row[2] >= FUZZY_THRESHOLD:
        return row[0], "fuzzy", round(row[2], 2), row[1]

    return None, "none", None, None


def ingest_invoice_summary(conn, xlsx_path: str) -> dict:
    """
    Loads Cafe/Inward rows from Invoice Summary - Pending.xlsx into
    staging.cafe_invoices. Dedup key: `filename`, enforced both here (a
    SELECT check) and at the database level (a UNIQUE index) - a filename
    already in staging, in ANY row_status (pending/verified/imported/
    deleted), is never re-inserted. This is what actually prevents an
    invoice being handled twice: once a filename has been staged once, it
    stays "seen" forever, even after the row is later marked imported.
    """
    df = pd.read_excel(xlsx_path, sheet_name=0)
    cafe_rows = df[
        _norm_key(df["category"]).isin(CAFE_CATEGORIES)
        & _norm_key(df["direction"]).isin(INWARD_DIRECTIONS)
    ]

    inserted, skipped = 0, 0
    with conn.cursor() as cur:
        for _, r in cafe_rows.iterrows():
            filename = to_none(r["filename"])
            if not filename:
                continue

            cur.execute("SELECT 1 FROM staging.cafe_invoices WHERE filename = %s", (filename,))
            if cur.fetchone():
                skipped += 1
                continue

            supplier_name = r["supplier"]
            supplier_id, match_type, match_score, candidate_name = match_supplier(cur, supplier_name)

            invoice_date = r["invoice_date"]
            invoice_date = invoice_date.date() if hasattr(invoice_date, "date") else invoice_date

            cur.execute(
                """
                INSERT INTO staging.cafe_invoices
                    (filename, supplier_name, supplier_id, invoice_number, invoice_date,
                     amount_ex_gst, gst_amount, amount_inc_gst, payment_status, notes,
                     match_type, match_score, candidate_name)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    filename, supplier_name, supplier_id, to_none(r["invoice_number"]), invoice_date,
                    to_none(r["amount_ex_gst"]), to_none(r["gst_amount"]), to_none(r["amount_inc_gst"]),
                    to_none(r.get("payment_status")) or "Unpaid", to_none(r.get("notes")),
                    match_type, match_score, candidate_name,
                ),
            )
            inserted += 1
    conn.commit()
    return {"inserted": inserted, "skipped": skipped}


def ingest_cafe_line_items(conn, xlsx_path: str) -> dict:
    """
    Loads Cafe Line Items - Pending.xlsx into staging.cafe_purchases, linked
    to the parent invoice via `filename`. A line whose filename doesn't
    match any staged invoice is skipped, not guessed at - it'll pick up
    automatically once that invoice is staged.

    Dedup is at the INVOICE level, not the line level: if staging.
    cafe_purchases already has ANY row for a given invoice_staging_id, none
    of that invoice's lines are re-inserted (its lines are treated as
    already loaded, full stop). This used to be a per-line content check
    (matching on item + amount) instead - which silently dropped genuinely
    repeated lines (e.g. several identical linen items at the same price
    on one invoice), losing real data rather than preventing a duplicate.
    Since an invoice's lines only ever need loading once - the same
    guarantee `filename` gives invoices themselves - an existence check at
    the invoice level is both correct and can't misfire on legitimate
    repeats within a single invoice.
    """
    df = pd.read_excel(xlsx_path, sheet_name=0)

    inserted, skipped_already_loaded, skipped_no_invoice = 0, 0, 0
    already_loaded_cache: dict = {}

    with conn.cursor() as cur:
        for _, r in df.iterrows():
            filename = to_none(r.get("filename"))
            if not filename:
                continue

            cur.execute("SELECT staging_id FROM staging.cafe_invoices WHERE filename = %s", (filename,))
            parent = cur.fetchone()
            if parent is None:
                skipped_no_invoice += 1
                continue
            invoice_staging_id = parent[0]

            if invoice_staging_id not in already_loaded_cache:
                cur.execute(
                    "SELECT 1 FROM staging.cafe_purchases WHERE invoice_staging_id = %s LIMIT 1",
                    (invoice_staging_id,),
                )
                already_loaded_cache[invoice_staging_id] = cur.fetchone() is not None

            if already_loaded_cache[invoice_staging_id]:
                skipped_already_loaded += 1
                continue

            item = r["item"]
            line_total = to_none(r.get("line_total"))
            purchase_date = r.get("purchase_date")
            purchase_date = purchase_date.date() if hasattr(purchase_date, "date") else to_none(purchase_date)

            cur.execute(
                """
                INSERT INTO staging.cafe_purchases
                    (invoice_staging_id, filename, purchase_date, category, item, qty,
                     unit_cost, line_total, gst_applicable, gst_declared, gst_assessed,
                     expense_type, surcharge_source, in_invoice_total, notes)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    invoice_staging_id, filename, purchase_date, to_none(r.get("category")), item,
                    to_none(r.get("qty")), to_none(r.get("unit_cost")), line_total,
                    to_bool(r.get("gst_applicable")), to_none(r.get("gst_declared")),
                    to_none(r.get("gst_assessed")), to_none(r.get("expense_type")),
                    to_none(r.get("surcharge_source")),
                    to_bool(r.get("in_invoice_total")) if to_none(r.get("in_invoice_total")) is not None else True,
                    to_none(r.get("notes")),
                ),
            )
            inserted += 1
    conn.commit()
    return {"inserted": inserted, "skipped_dup": skipped_already_loaded, "skipped_no_invoice": skipped_no_invoice}
