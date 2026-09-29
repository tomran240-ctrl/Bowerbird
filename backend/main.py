"""
Bowerbird Verifier - backend (invoice + line-item model)
----------------------------------------------------------
Rebuilt around the real production schema: each café invoice (staging.
cafe_invoices) owns a set of line items (staging.cafe_purchases), matching
cafe.invoices / cafe.purchases in 115kws. An invoice is "ready" once its
header is verified and every one of its (non-deleted) line items is
verified - only then can it be imported.

    export VERIFIER_DB_URL="postgresql://verifier_app:<password>@127.0.0.1:5432/kws115"
    export VERIFIER_PDF_ROOT="/Users/admin/Desktop/INBOX TO FILE"
    python3 -m uvicorn main:app --host 127.0.0.1 --port 8420

Then expose it on the tailnet only with `tailscale serve --bg 8420`.
Never bind this to 0.0.0.0.
"""

import re
import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Optional

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from ingest_lib import ingest_invoice_summary, ingest_cafe_line_items

BASE_DIR = Path(__file__).parent
DB_URL = os.environ.get("VERIFIER_DB_URL", "postgresql://verifier_app:testpass@127.0.0.1:5432/kws115_test")
# The real inbox - renamed files stay here until a separate filing step moves them.
PDF_ROOT = Path(os.environ.get("VERIFIER_PDF_ROOT", BASE_DIR / "sample_data" / "pdfs"))
# Where filed documents live. Colon-separated folders searched, by file name,
# for a record's provenance.source_document - the RULE-FN filed name.
PDF_ROOTS = [Path(x) for x in os.environ.get("VERIFIER_PDF_ROOTS", "").split(":") if x] or [PDF_ROOT]
_DOC_CACHE: dict = {}
# The two real staging workbooks - set these so the app can check for new
# rows itself. Left unset, auto-ingest is simply skipped (nothing breaks).
INVOICE_SUMMARY_PATH = os.environ.get("VERIFIER_INVOICE_SUMMARY_PATH")
LINE_ITEMS_PATH = os.environ.get("VERIFIER_LINE_ITEMS_PATH")

# Cutover switch. False once the cafe queue moved onto the registry grid.
LEGACY_AUTO_INGEST = os.environ.get("VERIFIER_LEGACY_AUTO_INGEST", "0") == "1"

RECONCILIATION_TOLERANCE = Decimal("0.02")
DATE_FIELDS = {"invoice_date", "purchase_date"}


def _normalize_date_field(field: str, value: Any) -> Any:
    """Accept DD/MM/YYYY (what the UI sends) as well as ISO, and fail with a
    clear 400 rather than letting an unparseable date reach Postgres as a
    raw, unhandled error."""
    if field not in DATE_FIELDS or value in (None, ""):
        return value
    s = str(value).strip()
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", s)
    if m:
        d, mo, y = m.groups()
        try:
            return datetime(int(y), int(mo), int(d)).date().isoformat()
        except ValueError:
            raise HTTPException(400, f"'{value}' isn't a valid date")
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    raise HTTPException(400, f"'{value}' isn't a recognised date - use DD/MM/YYYY")

app = FastAPI(title="Bowerbird Verifier")


from contextlib import contextmanager


@contextmanager
def db():
    """
    A plain `with conn:` on a psycopg2 connection commits/rolls back but
    does NOT close the connection - every request was leaking one. Fixed
    here so the connection is always closed when the request is done,
    regardless of how many endpoints already write `with db() as conn:`.
    """
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = False
    try:
        yield conn
    finally:
        conn.close()


def dictcur(conn):
    return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _invoice_summary(conn, staging_id: int):
    """Header + line-item counts + reconciliation, for the list view and the gate check."""
    with dictcur(conn) as cur:
        cur.execute(
            """
            SELECT staging_id, filename, supplier_name, supplier_id, invoice_number, invoice_date,
                   amount_ex_gst, gst_amount, amount_inc_gst, payment_status, notes,
                   match_type, match_score, candidate_name, flagged, row_status
            FROM staging.cafe_invoices WHERE staging_id = %s
            """,
            (staging_id,),
        )
        header = cur.fetchone()
        if header is None:
            return None

        cur.execute(
            """
            SELECT
                count(*) FILTER (WHERE row_status != 'deleted') AS total_lines,
                count(*) FILTER (WHERE row_status = 'verified') AS verified_lines,
                COALESCE(sum(line_total + COALESCE(gst_declared, gst_assessed, 0))
                         FILTER (WHERE row_status != 'deleted' AND in_invoice_total), 0) AS reconciled_sum
            FROM staging.cafe_purchases WHERE invoice_staging_id = %s
            """,
            (staging_id,),
        )
        line_stats = cur.fetchone()

    header_verified = header["row_status"] == "verified"
    lines_ready = line_stats["total_lines"] == 0 or line_stats["verified_lines"] == line_stats["total_lines"]
    amount_inc_gst = header["amount_inc_gst"] or Decimal("0")
    reconciled_sum = line_stats["reconciled_sum"] or Decimal("0")
    reconciliation_gap = amount_inc_gst - reconciled_sum
    reconciles = line_stats["total_lines"] == 0 or abs(reconciliation_gap) <= RECONCILIATION_TOLERANCE

    return {
        **header,
        "total_lines": line_stats["total_lines"],
        "verified_lines": line_stats["verified_lines"],
        "header_verified": header_verified,
        "ready_to_import": header_verified and lines_ready and header["row_status"] not in ("deleted", "imported"),
        "reconciliation_gap": reconciliation_gap,
        "reconciles": reconciles,
    }


# ---------------------------------------------------------------------------
# Invoice list + detail
# ---------------------------------------------------------------------------

def _auto_ingest(conn) -> Optional[dict]:
    """
    Checks the two real staging workbooks for anything new, if their paths
    are configured. Never raises - a malformed workbook or a locked file
    logs a warning and leaves the rest of the page working, rather than
    taking down the whole home screen over an ingestion hiccup.
    Returns None if auto-ingest isn't configured at all, so the frontend
    can tell "nothing new" apart from "not set up yet".
    """
    if not LEGACY_AUTO_INGEST:
        # Retired at cutover (migration 010). The cafe workbooks now reach
        # staging.record through shim_invoice_staging + staging_ingest, run by
        # /api/ingest-run. staging.cafe_invoices is read-only from here on, so
        # leaving this on would only produce permission errors on every page
        # load. The function is kept, not deleted, because the legacy list view
        # still reads those tables for the historical record.
        return None
    if not INVOICE_SUMMARY_PATH and not LINE_ITEMS_PATH:
        return None

    result = {"invoices_inserted": 0, "lines_inserted": 0, "errors": []}
    if INVOICE_SUMMARY_PATH and Path(INVOICE_SUMMARY_PATH).exists():
        try:
            stats = ingest_invoice_summary(conn, INVOICE_SUMMARY_PATH)
            result["invoices_inserted"] = stats["inserted"]
        except Exception as e:
            conn.rollback()
            result["errors"].append(f"Invoice Summary: {e}")
    if LINE_ITEMS_PATH and Path(LINE_ITEMS_PATH).exists():
        try:
            stats = ingest_cafe_line_items(conn, LINE_ITEMS_PATH)
            result["lines_inserted"] = stats["inserted"]
        except Exception as e:
            conn.rollback()
            result["errors"].append(f"Cafe Line Items: {e}")
    return result


@app.get("/api/invoices")
def list_invoices():
    with db() as conn:
        auto = _auto_ingest(conn)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT staging_id FROM staging.cafe_invoices WHERE row_status NOT IN ('deleted','imported') ORDER BY staging_id"
            )
            ids = [r[0] for r in cur.fetchall()]
        return {"invoices": [_invoice_summary(conn, i) for i in ids], "auto_ingest": auto}


@app.post("/api/refresh")
def manual_refresh():
    """Same auto-ingest check, callable on demand (the Refresh button)."""
    with db() as conn:
        auto = _auto_ingest(conn)
        if auto is None:
            raise HTTPException(400, "Auto-ingest isn't configured - set VERIFIER_INVOICE_SUMMARY_PATH / VERIFIER_LINE_ITEMS_PATH")
        return auto


@app.get("/api/invoices/{staging_id}")
def get_invoice(staging_id: int):
    with db() as conn:
        summary = _invoice_summary(conn, staging_id)
        if summary is None:
            raise HTTPException(404, "Invoice not found")
        with dictcur(conn) as cur:
            cur.execute(
                """
                SELECT staging_id AS _row_id, purchase_date, category, item, qty, unit_cost, line_total,
                       gst_applicable, gst_declared, gst_assessed, expense_type, surcharge_source,
                       in_invoice_total, notes, row_status
                FROM staging.cafe_purchases
                WHERE invoice_staging_id = %s AND row_status != 'deleted'
                ORDER BY staging_id
                """,
                (staging_id,),
            )
            lines = cur.fetchall()
    return {"invoice": summary, "lines": lines}


# ---------------------------------------------------------------------------
# Header edits + verify
# ---------------------------------------------------------------------------

HEADER_EDITABLE_FIELDS = {
    "supplier_name", "invoice_number", "invoice_date",
    "amount_ex_gst", "gst_amount", "amount_inc_gst", "notes", "payment_status",
}


class CellEdit(BaseModel):
    field: str
    value: Any


@app.get("/api/organisations")
def list_organisations():
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT id, name FROM contacts.organisations ORDER BY name")
        return cur.fetchall()


class NewOrganisation(BaseModel):
    name: str


@app.post("/api/organisations")
def create_organisation(body: NewOrganisation):
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "Name can't be blank")
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT id, name FROM contacts.organisations WHERE lower(name) = lower(%s)", (name,))
        existing = cur.fetchone()
        if existing:
            raise HTTPException(409, f"'{existing['name']}' is already registered (id {existing['id']})")

        # org_number follows the existing ORG-NNN convention - find the next free one
        cur.execute(
            r"SELECT org_number FROM contacts.organisations WHERE org_number ~ '^ORG-\d+$' ORDER BY (regexp_match(org_number, '^ORG-(\d+)$'))[1]::int DESC LIMIT 1"
        )
        last = cur.fetchone()
        next_n = int(last["org_number"].split("-")[1]) + 1 if last else 1
        org_number = f"ORG-{next_n:03d}"

        cur.execute(
            "INSERT INTO contacts.organisations (org_number, name) VALUES (%s, %s) RETURNING id, name",
            (org_number, name),
        )
        new_org = cur.fetchone()
        conn.commit()
    return new_org


class SetSupplierBody(BaseModel):
    supplier_id: int


@app.post("/api/invoices/{staging_id}/supplier")
def set_supplier(staging_id: int, body: SetSupplierBody):
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT id, name FROM contacts.organisations WHERE id = %s", (body.supplier_id,))
        org = cur.fetchone()
        if org is None:
            raise HTTPException(404, "That supplier doesn't exist")

        cur.execute(
            """
            UPDATE staging.cafe_invoices
            SET supplier_id = %s, match_type = 'alias', match_score = NULL, candidate_name = NULL
            WHERE staging_id = %s
            RETURNING supplier_name
            """,
            (body.supplier_id, staging_id),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(404, "Invoice not found")

        # a human just explicitly confirmed this mapping - alias it (or correct
        # a previous wrong alias) so the same printed name resolves cleanly next time
        cur.execute(
            """
            INSERT INTO normalisation.supplier_aliases (alias_text, organisation_id)
            VALUES (%s, %s)
            ON CONFLICT (alias_text) DO UPDATE SET organisation_id = EXCLUDED.organisation_id
            """,
            (row["supplier_name"], body.supplier_id),
        )
        conn.commit()
    return {"ok": True, "supplier_name": org["name"]}


@app.patch("/api/invoices/{staging_id}")
def edit_invoice_header(staging_id: int, edit: CellEdit):
    if edit.field not in HEADER_EDITABLE_FIELDS:
        raise HTTPException(400, f"'{edit.field}' is not editable")
    value = _normalize_date_field(edit.field, edit.value)
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            f"UPDATE staging.cafe_invoices SET {edit.field} = %s WHERE staging_id = %s RETURNING staging_id",
            (value, staging_id),
        )
        if cur.fetchone() is None:
            raise HTTPException(404, "Invoice not found")
        conn.commit()
    return {"ok": True}


class VerifyBody(BaseModel):
    verified: bool
    verified_by: str = "Tom"


@app.post("/api/invoices/{staging_id}/verify")
def verify_invoice_header(staging_id: int, body: VerifyBody):
    with db() as conn, conn.cursor() as cur:
        if body.verified:
            cur.execute(
                """
                UPDATE staging.cafe_invoices
                SET row_status = 'verified', verified_by = %s, verified_at = %s
                WHERE staging_id = %s
                RETURNING supplier_name, supplier_id, match_type
                """,
                (body.verified_by, datetime.now(timezone.utc), staging_id),
            )
            row = cur.fetchone()
            if row is None:
                raise HTTPException(404, "Invoice not found")
            supplier_name, supplier_id, match_type = row
            if match_type in ("exact", "fuzzy") and supplier_id is not None:
                cur.execute(
                    """
                    INSERT INTO normalisation.supplier_aliases (alias_text, organisation_id)
                    VALUES (%s, %s) ON CONFLICT (alias_text) DO NOTHING
                    """,
                    (supplier_name, supplier_id),
                )
        else:
            cur.execute(
                """
                UPDATE staging.cafe_invoices
                SET row_status = 'pending', verified_by = NULL, verified_at = NULL
                WHERE staging_id = %s RETURNING staging_id
                """,
                (staging_id,),
            )
            if cur.fetchone() is None:
                raise HTTPException(404, "Invoice not found")
        conn.commit()
    return {"ok": True}


@app.delete("/api/invoices/{staging_id}")
def delete_invoice(staging_id: int):
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE staging.cafe_invoices SET row_status = 'deleted' WHERE staging_id = %s RETURNING staging_id",
            (staging_id,),
        )
        if cur.fetchone() is None:
            raise HTTPException(404, "Invoice not found")
        conn.commit()
    return {"ok": True}


# ---------------------------------------------------------------------------
# Line item edits + verify
# ---------------------------------------------------------------------------

LINE_EDITABLE_FIELDS = {
    "purchase_date", "category", "item", "qty", "unit_cost", "line_total",
    "gst_applicable", "gst_declared", "gst_assessed", "expense_type",
    "surcharge_source", "in_invoice_total", "notes",
}


@app.post("/api/invoices/{staging_id}/lines")
def add_line(staging_id: int):
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT filename FROM staging.cafe_invoices WHERE staging_id = %s", (staging_id,))
        parent = cur.fetchone()
        if parent is None:
            raise HTTPException(404, "Invoice not found")
        cur.execute(
            """
            INSERT INTO staging.cafe_purchases (invoice_staging_id, filename, item, in_invoice_total, row_status)
            VALUES (%s, %s, 'New item', true, 'pending')
            RETURNING staging_id AS _row_id, purchase_date, category, item, qty, unit_cost, line_total,
                      gst_applicable, gst_declared, gst_assessed, expense_type, surcharge_source,
                      in_invoice_total, notes, row_status
            """,
            (staging_id, parent["filename"]),
        )
        new_line = cur.fetchone()
        conn.commit()
    return new_line


@app.patch("/api/invoices/{staging_id}/lines/{line_id}")
def edit_line(staging_id: int, line_id: int, edit: CellEdit):
    if edit.field not in LINE_EDITABLE_FIELDS:
        raise HTTPException(400, f"'{edit.field}' is not editable")
    value = _normalize_date_field(edit.field, edit.value)
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            f"""
            UPDATE staging.cafe_purchases SET {edit.field} = %s
            WHERE staging_id = %s AND invoice_staging_id = %s RETURNING staging_id
            """,
            (value, line_id, staging_id),
        )
        if cur.fetchone() is None:
            raise HTTPException(404, "Line not found")
        conn.commit()
    return {"ok": True}


@app.post("/api/invoices/{staging_id}/lines/{line_id}/verify")
def verify_line(staging_id: int, line_id: int, body: VerifyBody):
    with db() as conn, conn.cursor() as cur:
        new_status = "verified" if body.verified else "pending"
        verified_by = body.verified_by if body.verified else None
        verified_at = datetime.now(timezone.utc) if body.verified else None
        cur.execute(
            """
            UPDATE staging.cafe_purchases
            SET row_status = %s, verified_by = %s, verified_at = %s
            WHERE staging_id = %s AND invoice_staging_id = %s RETURNING staging_id
            """,
            (new_status, verified_by, verified_at, line_id, staging_id),
        )
        if cur.fetchone() is None:
            raise HTTPException(404, "Line not found")
        conn.commit()
    return {"ok": True}


@app.post("/api/invoices/{staging_id}/lines/verify-all")
def verify_all_lines(staging_id: int, body: VerifyBody):
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE staging.cafe_purchases
            SET row_status = 'verified', verified_by = %s, verified_at = %s
            WHERE invoice_staging_id = %s AND row_status = 'pending'
            """,
            (body.verified_by, datetime.now(timezone.utc), staging_id),
        )
        conn.commit()
    return {"ok": True}


@app.delete("/api/invoices/{staging_id}/lines/{line_id}")
def delete_line(staging_id: int, line_id: int):
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE staging.cafe_purchases SET row_status = 'deleted'
            WHERE staging_id = %s AND invoice_staging_id = %s RETURNING staging_id
            """,
            (line_id, staging_id),
        )
        if cur.fetchone() is None:
            raise HTTPException(404, "Line not found")
        conn.commit()
    return {"ok": True}


@app.get("/api/categories")
def list_categories():
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT category, expense_type FROM cafe.expense_categories ORDER BY category")
        return cur.fetchall()


def _find_document(name: str):
    """First PDF called `name` under any of PDF_ROOTS. Base name only - a path
    from a record is never trusted. Hits are cached; a moved file is re-searched."""
    if not name or name != os.path.basename(name) or not name.lower().endswith(".pdf"):
        return None
    hit = _DOC_CACHE.get(name)
    if hit and hit.exists():
        return hit
    for root in PDF_ROOTS:
        if not root.is_dir():
            continue
        found = next(root.rglob(name), None)
        if found is not None and found.is_file():
            _DOC_CACHE[name] = found
            return found
    return None


@app.get("/api/source-document/{name}")
def get_source_document(name: str):
    found = _find_document(name)
    if found is None:
        raise HTTPException(404, "PDF '%s' was not found under: %s. Set VERIFIER_PDF_ROOTS "
                                 "to the folder(s) it is filed in." % (name, ", ".join(map(str, PDF_ROOTS))))
    return FileResponse(found, media_type="application/pdf")


@app.get("/api/documents/{filename:path}")
def get_document(filename: str):
    candidate = (PDF_ROOT / filename).resolve()
    if PDF_ROOT.resolve() not in candidate.parents and candidate != PDF_ROOT.resolve():
        raise HTTPException(400, "Invalid path")
    if not candidate.exists():
        raise HTTPException(404, "Document not found")
    return FileResponse(candidate, media_type="application/pdf")


# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

class ImportBody(BaseModel):
    imported_by: str = "Tom"


@app.post("/api/import")
def import_all(body: ImportBody):
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT staging_id FROM staging.cafe_invoices WHERE row_status NOT IN ('deleted','imported')"
            )
            ids = [r[0] for r in cur.fetchall()]
        summaries = [_invoice_summary(conn, i) for i in ids]
        not_ready = [s["filename"] for s in summaries if not s["ready_to_import"]]
        if not_ready:
            raise HTTPException(
                409,
                detail={"message": "Not every invoice is fully verified yet.", "blocking": not_ready},
            )
        if not summaries:
            return {"ok": True, "imported_invoices": 0, "imported_lines": 0}

        errors = []
        with dictcur(conn) as cur:
            for s in summaries:
                cur.execute(
                    "SELECT 1 FROM cafe.invoices WHERE supplier_name = %s AND invoice_number = %s",
                    (s["supplier_name"], s["invoice_number"]),
                )
                if cur.fetchone():
                    errors.append(f"{s['filename']}: {s['supplier_name']} / {s['invoice_number']} already in cafe.invoices")
                if s["supplier_id"] is not None:
                    cur.execute("SELECT 1 FROM contacts.organisations WHERE id = %s", (s["supplier_id"],))
                    if cur.fetchone() is None:
                        errors.append(f"{s['filename']}: supplier_id {s['supplier_id']} not found")

                cur.execute(
                    "SELECT staging_id, category, expense_type, surcharge_source, in_invoice_total FROM staging.cafe_purchases WHERE invoice_staging_id = %s AND row_status = 'verified'",
                    (s["staging_id"],),
                )
                for line in cur.fetchall():
                    if line["expense_type"] not in ("COGS", "Operating Expense", "Non-Business", "Capital"):
                        errors.append(f"{s['filename']}: line {line['staging_id']} has invalid expense_type '{line['expense_type']}'")
                    if line["surcharge_source"] and line["category"] not in ("Cafe - Card Surcharge", "Cafe - Adjustment"):
                        errors.append(f"{s['filename']}: line {line['staging_id']} has surcharge_source but category '{line['category']}' isn't a surcharge/adjustment category")
                    if not line["in_invoice_total"] and line["category"] not in ("Cafe - Card Surcharge", "Cafe - Adjustment"):
                        errors.append(f"{s['filename']}: line {line['staging_id']} is excluded from the invoice total but isn't a surcharge/adjustment category")

        if errors:
            conn.rollback()
            raise HTTPException(422, detail={"message": "Import blocked by validation errors.", "errors": errors})

        imported_invoices, imported_lines = 0, 0
        with dictcur(conn) as cur:
            for s in summaries:
                cur.execute(
                    """
                    INSERT INTO cafe.invoices
                        (property_code, supplier_id, supplier_name, invoice_number, invoice_date,
                         payment_status, amount_ex_gst, gst_amount, amount_inc_gst, source_file, notes)
                    VALUES ('115KW', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    RETURNING id
                    """,
                    (
                        s["supplier_id"], s["supplier_name"], s["invoice_number"], s["invoice_date"],
                        s["payment_status"], s["amount_ex_gst"], s["gst_amount"], s["amount_inc_gst"],
                        s["filename"], s["notes"],
                    ),
                )
                invoice_id = cur.fetchone()["id"]

                cur.execute(
                    "SELECT * FROM staging.cafe_purchases WHERE invoice_staging_id = %s AND row_status = 'verified'",
                    (s["staging_id"],),
                )
                lines = cur.fetchall()
                for line in lines:
                    cur.execute(
                        """
                        INSERT INTO cafe.purchases
                            (property_code, supplier_id, supplier_name, purchase_date, category, item,
                             qty, unit_cost, line_total, notes, invoice_number, gst_applicable, gst_assessed,
                             expense_type, invoice_id, gst_declared, gst_status, surcharge_source, in_invoice_total)
                        VALUES ('115KW', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'Auto', %s, %s)
                        """,
                        (
                            s["supplier_id"], s["supplier_name"], line["purchase_date"], line["category"], line["item"],
                            line["qty"], line["unit_cost"], line["line_total"], line["notes"], s["invoice_number"],
                            line["gst_applicable"], line["gst_assessed"], line["expense_type"], invoice_id,
                            line["gst_declared"], line["surcharge_source"], line["in_invoice_total"],
                        ),
                    )
                    cur.execute(
                        "UPDATE staging.cafe_purchases SET row_status = 'imported', imported_at = %s WHERE staging_id = %s",
                        (datetime.now(timezone.utc), line["staging_id"]),
                    )
                    imported_lines += 1

                cur.execute(
                    "UPDATE staging.cafe_invoices SET row_status = 'imported', imported_at = %s WHERE staging_id = %s",
                    (datetime.now(timezone.utc), s["staging_id"]),
                )
                imported_invoices += 1

        conn.commit()

    return {"ok": True, "imported_by": body.imported_by, "imported_invoices": imported_invoices, "imported_lines": imported_lines}


# ---------------------------------------------------------------------------
# Navigation and the two process pages (migration 006)
# ---------------------------------------------------------------------------

def _table_present(cur, qualified_name: str) -> bool:
    """
    The nav degrades rather than breaks: before migration 006 is run there is
    no nav_tab table, /api/nav returns nothing, and the page falls back to the
    single cafe view it had before. No ordering dependency between deploying
    the code and running the migration.
    """
    cur.execute("SELECT to_regclass(%s) IS NOT NULL AS present", (qualified_name,))
    return bool(cur.fetchone()["present"])


def _pending_count(cur, tab):
    """
    A tab's badge must agree with the list the tab shows. The cafe queue is
    still served by the legacy staging.cafe_invoices table, so it counts that;
    everything else counts staging.record. Which one is a property of the tab
    row, not a special case in here - see count_source in migration 006.

    Parents only. A badge is a count of things to work through, and an
    invoice with thirty lines is one job, not thirty-one.
    """
    source = tab["count_source"]
    if source == "legacy_cafe":
        cur.execute("SELECT count(*) AS n FROM staging.cafe_invoices WHERE row_status = 'pending'")
        return cur.fetchone()["n"]
    if source == "record":
        sources = tab.get("sources") or []
        if not sources:
            return None
        # A tab's sources are (record_type, filter) pairs, so one record type
        # can appear on two tabs showing different slices - kw_invoice on both
        # 115KW and 117KW. An empty filter matches everything, because
        # payload @> '{}' is true for any payload.
        cur.execute(
            "SELECT count(*) AS n FROM staging.record r "
            "WHERE r.row_status = 'pending' AND r.parent_uid IS NULL "
            "  AND EXISTS (SELECT 1 FROM jsonb_array_elements(%s::jsonb) src "
            "              WHERE r.record_type = src->>'record_type' "
            "                AND r.payload @> (src->'filter'))",
            (json.dumps(sources),),
        )
        return cur.fetchone()["n"]
    return None


@app.get("/api/nav")
def nav():
    with db() as conn, dictcur(conn) as cur:
        if not _table_present(cur, "staging.nav_tab"):
            return {"tabs": []}
        if not _table_present(cur, "staging.nav_tab_source"):
            # Migration 007 not run yet. Nothing is mapped, so every queue
            # renders its "no record type registered" state rather than 500.
            return {"tabs": []}
        cur.execute(
            """
            SELECT t.tab_key, t.label, t.kind, t.route, t.count_source, t.sort_order,
                   coalesce(jsonb_agg(jsonb_build_object('record_type', s.record_type,
                                                         'filter', s.filter)
                                      ORDER BY s.sort_order, s.record_type)
                            FILTER (WHERE rt.record_type IS NOT NULL), '[]'::jsonb) AS sources,
                   coalesce(array_agg(s.record_type ORDER BY s.record_type)
                            FILTER (WHERE rt.record_type IS NOT NULL), '{}') AS record_types
            FROM staging.nav_tab t
            LEFT JOIN staging.nav_tab_source s ON s.tab_key = t.tab_key
            LEFT JOIN staging.record_type rt
                   ON rt.record_type = s.record_type AND rt.active
            WHERE t.active
            GROUP BY t.tab_key, t.label, t.kind, t.route, t.count_source, t.sort_order
            ORDER BY t.sort_order
            """
        )
        tabs = [dict(r) for r in cur.fetchall()]
        for tab in tabs:
            tab["pending"] = _pending_count(cur, tab)
        return {"tabs": tabs}


@app.get("/api/batches")
def list_batches(limit: int = 50):
    with db() as conn, dictcur(conn) as cur:
        if not _table_present(cur, "staging.batch"):
            return []
        cur.execute(
            "SELECT batch_id, record_type, produced_by, produced_at, source_file, "
            "declared_rows, ingested_rows, status, reject_reason, ingested_at, ingested_by "
            "FROM staging.batch ORDER BY ingested_at DESC LIMIT %s",
            (limit,),
        )
        return cur.fetchall()


@app.get("/api/imports")
def list_imports(limit: int = 100):
    """Both paths, newest first, so the history does not lose the legacy rows
    when the cafe queue moves onto the registry driven grid."""
    with db() as conn, dictcur(conn) as cur:
        parts = [
            "SELECT 'cafe_invoice' AS record_type, filename AS reference, "
            "supplier_name AS party, amount_inc_gst::text AS amount, verified_by, "
            "imported_at FROM staging.cafe_invoices WHERE row_status = 'imported'"
        ]
        if _table_present(cur, "staging.record"):
            parts.append(
                "SELECT record_type, natural_key->>'filename' AS reference, "
                "party_name AS party, payload->>'amount_inc_gst' AS amount, verified_by, "
                "imported_at FROM staging.record "
                "WHERE row_status = 'imported' AND parent_uid IS NULL"
            )
        cur.execute(
            " UNION ALL ".join(parts) + " ORDER BY imported_at DESC NULLS LAST LIMIT %s",
            (limit,),
        )
        return cur.fetchall()


# ---------------------------------------------------------------------------
# The registry driven queue and record views (migrations 005-007)
#
# Nothing below knows what a cafe invoice or an electricity bill is. Every
# column, label, editor and validation rule comes from staging.record_type.
# Registering a record type is what makes its queue work; no edit here.
# ---------------------------------------------------------------------------

from staging_ingest import validate_field as _validate_field


def _spec_for(cur, record_type):
    cur.execute(
        "SELECT record_type, label, parent_type, target_schema, target_table, "
        "field_spec, validation FROM staging.record_type WHERE record_type = %s",
        (record_type,),
    )
    row = cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Unknown record type: %s" % record_type)
    return dict(row)


def _tab_sources(cur, tab_key):
    cur.execute(
        "SELECT s.record_type, s.filter FROM staging.nav_tab_source s "
        "JOIN staging.record_type rt ON rt.record_type = s.record_type AND rt.active "
        "WHERE s.tab_key = %s ORDER BY s.sort_order, s.record_type",
        (tab_key,),
    )
    return [dict(r) for r in cur.fetchall()]


def _summary_field_names(field_spec):
    """
    What to show on a queue row, worked out from the spec rather than named
    per type. Title is the first required text field, date the first date
    field, amount the inc-GST field where there is one.
    """
    fields = field_spec.get("fields", [])
    names = [f["name"] for f in fields]
    title = next((f["name"] for f in fields
                  if f.get("type") == "text" and f.get("required")), None)
    date = next((f["name"] for f in fields if f.get("type") == "date"), None)
    if "amount_inc_gst" in names:
        amount = "amount_inc_gst"
    else:
        amount = next((f["name"] for f in fields if f.get("type") == "money"), None)
    return title, date, amount


def _coerce(field, raw):
    """UI value to stored value. DD/MM/YYYY is accepted because that is what
    the date inputs emit; everything else is passed through for the shared
    validator to judge."""
    kind = field.get("type")
    if raw is None or (isinstance(raw, str) and raw.strip() == ""):
        return None
    if kind == "date":
        return _normalize_date_field(field["name"], raw)
    if kind in ("money", "number"):
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            return raw
        try:
            return float(str(raw).replace(",", "").replace("$", "").strip())
        except ValueError:
            return raw
    if kind in ("text", "longtext", "lookup") and isinstance(raw, str):
        return raw.strip() or None
    if kind == "boolean":
        if isinstance(raw, bool):
            return raw
        return str(raw).strip().lower() in ("true", "yes", "1", "y", "t", "on")
    return raw


def _reconcile(cur, record_uid, spec):
    """
    Reconciliation, declared by the registry rather than coded per type.
    validation.reconcile names the child type, the sum to compute and the
    header field to compare it against; the named sums live here so a new
    record type declares one rather than needing new code.

    line_total_inc_gst: sum of line_total + GST (gst_declared, else legacy gst_assessed) over children that
    are inside the invoice total. A line marked out-of-total (a card
    surcharge, an adjustment) is excluded, which is the whole reason that
    flag exists.
    """
    rule = (spec["validation"] or {}).get("reconcile")
    if not rule:
        return None
    what = rule.get("sum")
    against = rule.get("against") or "amount_inc_gst"
    mode = rule.get("mode", "warn")

    if what == "line_total_inc_gst":
        cur.execute(
            "SELECT coalesce(sum("
            "   (payload->>'line_total')::numeric "
            "   + coalesce((payload->>'gst_declared')::numeric, (payload->>'gst_assessed')::numeric, 0)"
            "), 0) AS total, count(*) AS lines, count(*) AS with_field "
            "FROM staging.record "
            "WHERE parent_uid = %s AND record_type = %s AND row_status <> 'deleted' "
            "  AND coalesce((payload->>'in_invoice_total')::boolean, true)",
            (record_uid, rule["children"]),
        )
    else:
        # Any other name is a numeric field on the child payload, summed as is.
        # Lines lacking the field are counted so a mis-spelt field in the
        # registry is reported, not read as a total of zero.
        cur.execute(
            "SELECT coalesce(sum((payload->>%s)::numeric), 0) AS total, count(*) AS lines, "
            "       count(payload->>%s) AS with_field "
            "FROM staging.record "
            "WHERE parent_uid = %s AND record_type = %s AND row_status <> 'deleted'",
            (what, what, record_uid, rule["children"]),
        )
    got = cur.fetchone()
    if got["with_field"] != got["lines"]:
        return {"error": "%d of %d %s line(s) have no '%s' value to sum"
                         % (got["lines"] - got["with_field"], got["lines"],
                            rule["children"], what),
                "mode": mode}
    return {"lines": got["lines"], "actual": got["total"], "against": against,
            "sum": what, "mode": mode,
            "tolerance": rule.get("tolerance", "0.02" if what == "line_total_inc_gst" else "0.05")}


def _reconcile_verdict(header_value, calc, tolerance=None):
    if not calc or "error" in calc or calc["lines"] == 0:
        return None
    if header_value is None:
        return None
    try:
        expected = Decimal(str(header_value))
        actual = Decimal(str(calc["actual"]))
        tol = Decimal(str(tolerance if tolerance is not None else calc.get("tolerance", "0.02")))
    except (ArithmeticError, ValueError):
        return None
    variance = (expected - actual).quantize(Decimal("0.01"))
    return {"expected": float(expected), "actual": float(actual),
            "variance": float(variance), "ok": abs(variance) <= tol,
            "lines": calc["lines"], "mode": calc["mode"],
            "against": calc["against"], "sum": calc["sum"]}


def _party_normalised(spec, match_type, party_id):
    """None when the type has no party. A party counts as normalised only when
    it was confirmed (alias) or matched exactly - a fuzzy guess carries a
    party_id too, and must not pass for one."""
    if not (spec["field_spec"] or {}).get("party_field"):
        return None
    return bool(party_id) and match_type in ("alias", "exact")


def _reconcile_for(cur, record_uid, payload, spec):
    calc = _reconcile(cur, record_uid, spec)
    against = (calc or {}).get("against", "amount_inc_gst")
    return calc, _reconcile_verdict(payload.get(against), calc)


def _refuse_on_reconcile(calc, verdict):
    if verdict and not verdict["ok"] and verdict["mode"] == "block":
        raise HTTPException(status_code=422, detail={
            "message": "Blocked: the %d line(s) sum to %s but the header says %s (%s), out by %s. "
                       "Correct the lines or the header first."
                       % (verdict["lines"], verdict["actual"], verdict["expected"],
                          verdict["against"], abs(verdict["variance"])),
            "reconcile": verdict})


def _cross_check_status(instruction_hours, rostered_hours, tolerance):
    """
    One person-week: what the pay instruction says against what the Square
    roster says. Same statuses and same test as payroll.v_pay_variance so the
    grid and the view cannot disagree. Pure, so it is testable without a database.
    """
    if instruction_hours is None:
        return {"status": "NO INSTRUCTION HOURS", "variance": None}
    if rostered_hours is None:
        return {"status": "NOT IN HOURS RUN", "variance": None}
    variance = (Decimal(str(instruction_hours)) - Decimal(str(rostered_hours))).quantize(Decimal("0.01"))
    return {"status": "OK" if abs(variance) <= tolerance else "VARIANCE",
            "variance": float(variance)}


def _cross_check(cur, record_uid, record_type, payload, spec):
    """
    validation.cross_check, declared by the registry (only payroll_instruction
    declares one today). For each child line, find the Square ROSTERED hours for
    the same employee and week and compare. Production wins where it has the
    week, staged hours runs (pending or verified) stand in where it does not.
    Returns None when the record has no cross_check or it does not apply.
    """
    rule = (spec["validation"] or {}).get("cross_check")
    if not rule or rule.get("against_type") != "payroll_hours_line":
        return None
    if any(payload.get(k) != v for k, v in (rule.get("only_when") or {}).items()):
        return None
    week_end = payload.get("period_end")
    if not week_end:
        return None
    tolerance = Decimal(str(rule.get("tolerance_hours", "0.10")))

    cur.execute(
        "SELECT record_uid, natural_key->>'employee_code' AS employee_code, "
        "       payload->>'total_hours' AS total_hours "
        "FROM staging.record WHERE parent_uid = %s AND row_status <> 'deleted'",
        (record_uid,),
    )
    lines = [dict(r) for r in cur.fetchall()]

    cur.execute(
        "SELECT (SELECT count(*) FROM payroll.hours_run WHERE pay_week_end = %(w)s) AS prod_runs, "
        "       (SELECT count(*) FROM staging.record "
        "         WHERE record_type = 'payroll_hours_run' AND row_status IN ('pending','verified') "
        "           AND payload->>'pay_week_end' = %(w)s::text) AS staged_runs",
        {"w": week_end},
    )
    runs = cur.fetchone()

    cur.execute(
        "SELECT e.employee_code, sum(hl.rostered_hours) AS hours "
        "FROM payroll.hours_run r JOIN payroll.hours_line hl ON hl.run_id = r.id "
        "JOIN payroll.employee e ON e.square_team_member_id = hl.square_team_member_id "
        "WHERE r.pay_week_end = %s GROUP BY e.employee_code",
        (week_end,),
    )
    prod = {r["employee_code"]: r["hours"] for r in cur.fetchall()}

    cur.execute(
        "SELECT e.employee_code, sum((c.payload->>'rostered_hours')::numeric) AS hours "
        "FROM staging.record p JOIN staging.record c ON c.parent_uid = p.record_uid "
        "JOIN payroll.employee e ON e.square_team_member_id = c.natural_key->>'square_team_member_id' "
        "WHERE p.record_type = 'payroll_hours_run' AND p.row_status IN ('pending','verified') "
        "  AND p.payload->>'pay_week_end' = %s::text "
        "  AND c.record_type = 'payroll_hours_line' AND c.row_status <> 'deleted' "
        "GROUP BY e.employee_code",
        (week_end,),
    )
    staged = {r["employee_code"]: r["hours"] for r in cur.fetchall()}

    out = {}
    for ln in lines:
        code = ln["employee_code"]
        hours = prod.get(code, staged.get(code))
        if not (runs["prod_runs"] or runs["staged_runs"]):
            res = {"status": "NO HOURS RUN", "variance": None}
        else:
            res = _cross_check_status(ln["total_hours"], hours, tolerance)
        res.update({"employee_code": code, "instruction_hours": ln["total_hours"],
                    "rostered_hours": None if hours is None else float(hours)})
        out[ln["record_uid"]] = res
    return {"mode": rule.get("mode", "warn"), "tolerance_hours": float(tolerance),
            "week_end": week_end, "lines": out}


def _cross_check_blockers(xc, only_uid=None):
    """Lines a block-mode cross_check refuses to let through."""
    if not xc or xc["mode"] != "block":
        return []
    return [v for uid, v in xc["lines"].items()
            if v["status"] == "VARIANCE" and (only_uid is None or uid == only_uid)]


def _refuse_on_cross_check(blockers):
    if blockers:
        names = ", ".join("%s (%+.2f h)" % (b["employee_code"], b["variance"]) for b in blockers)
        raise HTTPException(status_code=422, detail={
            "message": "Blocked: pay instruction differs from Square rostered hours by more "
                       "than the tolerance for %s. Correct the hours or the record first." % names,
            "cross_check": blockers})


class IngestRunBody(BaseModel):
    by: str = "Tom"


@app.post("/api/ingest-run")
def ingest_run(body: IngestRunBody):
    """
    Runs the ingester over whatever producers have left in the Staging Inbox.

    It no longer runs shim_invoice_staging.py. Producers write their own
    envelope files now - weekly-inbox-filing-review through stage_records.py,
    and the payroll and electricity shims directly - so running the workbook
    converter here as well would make two producers of the same records. Under
    RULE-STG v2 that is worse than a duplicate: the two would compute slightly
    different payloads from the same natural key, and each Refresh would amend
    the other's record indefinitely.

    shim_invoice_staging.py still exists and still works by hand, for draining
    whatever is left in the old workbooks. Nothing calls it automatically.

    Run as a subprocess on purpose: a malformed batch or a missing library then
    fails as a non-zero exit and captured output, instead of raising inside the
    request and taking the page down with it. Whatever it prints comes back for
    the toast, and a rejected batch is on the Batches page.
    """
    import subprocess

    steps = []
    for script, label in (("staging_ingest.py", "ingest"),):
        path = BASE_DIR / script
        if not path.exists():
            steps.append({"step": label, "rc": None, "output": "%s not found" % script})
            continue
        try:
            done = subprocess.run(
                [sys.executable, str(path)],
                cwd=str(BASE_DIR), capture_output=True, text=True, timeout=300,
            )
            steps.append({"step": label, "rc": done.returncode,
                          "output": (done.stdout or "") + (done.stderr or "")})
            if done.returncode != 0:
                break
        except subprocess.TimeoutExpired:
            steps.append({"step": label, "rc": None, "output": "timed out after 300s"})
            break
    return {"ok": all(s["rc"] == 0 for s in steps), "steps": steps}


class PromoteBody(BaseModel):
    tab_key: str
    dry_run: bool = False


@app.post("/api/promote")
def promote_tab(body: PromoteBody):
    """
    Promote everything verified on a tab, one record type at a time.

    Runs promote.py as a subprocess for the same reason /api/ingest-run does:
    a promotion writes to production, and it should fail as a non-zero exit
    with captured output rather than as an exception inside a web request.
    The whole-batch block still applies per record type - one duplicate
    refuses that type's promotion and writes nothing.
    """
    import subprocess

    try:
        from promote import PROMOTERS
    except Exception as exc:
        raise HTTPException(500, detail="promote.py is not importable: %s" % exc)

    with db() as conn, dictcur(conn) as cur:
        types = [s["record_type"] for s in _tab_sources(cur, body.tab_key)
                 if s["record_type"] in PROMOTERS]
    if not types:
        return {"ok": True, "steps": [],
                "message": "Nothing on this tab has a promotion path yet."}

    steps = []
    for rt in types:
        cmd = [sys.executable, str(BASE_DIR / "promote.py"), "--type", rt]
        if body.dry_run:
            cmd.append("--dry-run")
        try:
            done = subprocess.run(cmd, cwd=str(BASE_DIR), capture_output=True,
                                  text=True, timeout=600)
            steps.append({"record_type": rt, "rc": done.returncode,
                          "output": (done.stdout or "") + (done.stderr or "")})
        except subprocess.TimeoutExpired:
            steps.append({"record_type": rt, "rc": None,
                          "output": "timed out after 600s"})
    return {"ok": all(s["rc"] == 0 for s in steps), "steps": steps}


class ImportOneBody(BaseModel):
    dry_run: bool = False
    by: str = "Tom"


@app.post("/api/record/{record_uid}/import")
def import_record(record_uid: str, body: ImportOneBody):
    """
    Promote one verified record and its lines. Runs promote.py --only-uid as a
    subprocess, for the reason /api/promote does: same code path, same blocks,
    a non-zero exit with captured output rather than an exception in a request.
    """
    import subprocess

    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT record_type, parent_uid, row_status FROM staging.record "
                    "WHERE record_uid = %s", (record_uid,))
        row = cur.fetchone()
    if row is None:
        raise HTTPException(404, "No such record")
    if row["parent_uid"]:
        raise HTTPException(422, "Import the invoice, not one of its lines.")
    if row["row_status"] != "verified":
        raise HTTPException(422, detail={"message": "Verify the record (and its lines) first. "
                                                    "Status is '%s'." % row["row_status"]})
    cmd = [sys.executable, str(BASE_DIR / "promote.py"), "--type", row["record_type"],
           "--only-uid", record_uid, "--by", body.by]
    if body.dry_run:
        cmd.append("--dry-run")
    try:
        done = subprocess.run(cmd, cwd=str(BASE_DIR), capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        raise HTTPException(504, "promote.py timed out after 300s")
    return {"ok": done.returncode == 0, "dry_run": body.dry_run,
            "output": (done.stdout or "") + (done.stderr or "")}


@app.get("/api/queue/{tab_key}")
def queue(tab_key: str):
    with db() as conn, dictcur(conn) as cur:
        sources = _tab_sources(cur, tab_key)
        if not sources:
            return {"tab_key": tab_key, "sources": [], "records": []}

        cur.execute(
            """
            SELECT r.record_uid, r.record_type, r.party_name, r.party_id, r.flagged,
                   r.match_type, r.match_score, r.candidate_name, r.row_status,
                   r.payload, r.natural_key, r.created_at,
                   (SELECT count(*) FROM staging.record c
                     WHERE c.parent_uid = r.record_uid AND c.row_status <> 'deleted')
                       AS child_count,
                   (SELECT count(*) FROM staging.record c
                     WHERE c.parent_uid = r.record_uid AND c.row_status = 'verified')
                       AS child_verified
            FROM staging.record r
            WHERE r.parent_uid IS NULL
              AND r.row_status IN ('pending','verified')
              AND EXISTS (SELECT 1 FROM jsonb_array_elements(%s::jsonb) src
                          WHERE r.record_type = src->>'record_type'
                            AND r.payload @> (src->'filter'))
            ORDER BY r.created_at, r.record_uid
            """,
            (json.dumps([{"record_type": s["record_type"], "filter": s["filter"]}
                         for s in sources]),),
        )
        rows = [dict(r) for r in cur.fetchall()]

        specs = {}
        out = []
        for r in rows:
            rt = r["record_type"]
            if rt not in specs:
                specs[rt] = _spec_for(cur, rt)
            title_f, date_f, amount_f = _summary_field_names(specs[rt]["field_spec"])
            payload = r["payload"] or {}
            ready = r["row_status"] == "verified" and r["child_verified"] == r["child_count"]
            calc, verdict = _reconcile_for(cur, r["record_uid"], payload, specs[rt])
            out.append({
                "record_uid": r["record_uid"],
                "record_type": rt,
                "type_label": specs[rt]["label"],
                "title": r["party_name"] or payload.get(title_f) or rt,
                "reference": payload.get(title_f),
                "date": payload.get(date_f),
                "amount": payload.get(amount_f),
                "flagged": r["flagged"],
                "party_normalised": _party_normalised(specs[rt], r["match_type"], r["party_id"]),
                "match_type": r["match_type"],
                "candidate_name": r["candidate_name"],
                "row_status": r["row_status"],
                "child_count": r["child_count"],
                "child_verified": r["child_verified"],
                "ready_to_import": ready,
                "reconciles": None if verdict is None else verdict["ok"],
            })
        return {"tab_key": tab_key,
                "sources": [s["record_type"] for s in sources],
                "records": out}


@app.get("/api/record/{record_uid}")
def get_record(record_uid: str):
    with db() as conn, dictcur(conn) as cur:
        cur.execute(
            "SELECT record_uid, record_type, parent_uid, seq, natural_key, payload, "
            "provenance, party_name, party_id, match_type, match_score, candidate_name, "
            "flagged, row_status, verified_by, verified_at FROM staging.record "
            "WHERE record_uid = %s",
            (record_uid,),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="No such record")
        record = dict(row)
        spec = _spec_for(cur, record["record_type"])

        cur.execute(
            "SELECT record_uid, record_type, seq, natural_key, payload, provenance, "
            "row_status, verified_by FROM staging.record "
            "WHERE parent_uid = %s AND row_status <> 'deleted' "
            "ORDER BY record_type, seq, record_uid",
            (record_uid,),
        )
        kids = [dict(r) for r in cur.fetchall()]

        groups, order = {}, []
        for k in kids:
            rt = k["record_type"]
            if rt not in groups:
                child_spec = _spec_for(cur, rt)
                groups[rt] = {"record_type": rt, "label": child_spec["label"],
                              "field_spec": child_spec["field_spec"],
                              "validation": child_spec["validation"], "rows": []}
                order.append(rt)
            groups[rt]["rows"].append(k)

        calc, verdict = _reconcile_for(cur, record_uid, record["payload"] or {}, spec)
        xc = _cross_check(cur, record_uid, record["record_type"], record["payload"] or {}, spec)

        try:
            from promote import PROMOTERS
            importable = record["record_type"] in PROMOTERS and record["parent_uid"] is None
        except Exception:
            importable = False
        return {"record": record, "spec": spec,
                "party_normalised": _party_normalised(spec, record["match_type"], record["party_id"]),
                "importable": importable,
                "children": [groups[rt] for rt in order],
                "reconcile": verdict,
                "reconcile_error": (calc or {}).get("error"), "cross_check": xc}


@app.patch("/api/record/{record_uid}")
def edit_record(record_uid: str, edit: CellEdit):
    with db() as conn, dictcur(conn) as cur:
        cur.execute(
            "SELECT record_type, payload, row_status FROM staging.record WHERE record_uid = %s",
            (record_uid,),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="No such record")
        spec = _spec_for(cur, row["record_type"])
        fields = {f["name"]: f for f in spec["field_spec"].get("fields", [])}
        field = fields.get(edit.field)
        if field is None:
            raise HTTPException(
                status_code=400,
                detail="'%s' is not a field of %s. The registry decides what is "
                       "editable here." % (edit.field, row["record_type"]))
        if field.get("editable") is False:
            raise HTTPException(status_code=400, detail="'%s' is not editable" % edit.field)

        value = _coerce(field, edit.value)
        errors = _validate_field(field, value,
                                 spec["validation"].get("enums", {}), "this record")
        if errors:
            raise HTTPException(status_code=400, detail={"errors": errors})

        old = (row["payload"] or {}).get(edit.field)
        cur.execute(
            "UPDATE staging.record SET payload = jsonb_set(payload, %s, %s::jsonb, true) "
            "WHERE record_uid = %s",
            ("{%s}" % edit.field, json.dumps(value), record_uid),
        )
        cur.execute(
            "INSERT INTO staging.record_edit (record_uid, field, old_value, new_value, edited_by) "
            "VALUES (%s,%s,%s,%s,%s)",
            (record_uid, edit.field,
             None if old is None else str(old),
             None if value is None else str(value), "Tom"),
        )
        conn.commit()
        return {"ok": True, "field": edit.field, "value": value}


@app.post("/api/record/{record_uid}/verify")
def verify_record(record_uid: str, body: VerifyBody):
    with db() as conn, dictcur(conn) as cur:
        if body.verified:
            cur.execute("SELECT record_type, payload, parent_uid FROM staging.record "
                        "WHERE record_uid = %s AND row_status IN ('pending','verified')",
                        (record_uid,))
            row = cur.fetchone()
            if row is not None:
                # A line is checked on its own; a parent on all of its lines.
                parent_uid = row["parent_uid"] or record_uid
                cur.execute("SELECT record_type, payload FROM staging.record WHERE record_uid = %s",
                            (parent_uid,))
                prow = cur.fetchone()
                pspec = _spec_for(cur, prow["record_type"])
                xc = _cross_check(cur, parent_uid, prow["record_type"], prow["payload"] or {}, pspec)
                _refuse_on_cross_check(_cross_check_blockers(
                    xc, only_uid=record_uid if row["parent_uid"] else None))
                if not row["parent_uid"]:
                    _refuse_on_reconcile(*_reconcile_for(
                        cur, record_uid, row["payload"] or {}, pspec))
        cur.execute(
            "UPDATE staging.record SET row_status = %s, verified_by = %s, verified_at = %s "
            "WHERE record_uid = %s AND row_status IN ('pending','verified')",
            ("verified" if body.verified else "pending",
             body.verified_by if body.verified else None,
             datetime.now(timezone.utc) if body.verified else None,
             record_uid),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="No such record, or it is not open")
        conn.commit()
        return {"ok": True}


@app.post("/api/record/{record_uid}/verify-children")
def verify_children(record_uid: str, body: VerifyBody):
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT record_type, payload FROM staging.record WHERE record_uid = %s",
                    (record_uid,))
        prow = cur.fetchone()
        if prow is not None:
            xc = _cross_check(cur, record_uid, prow["record_type"], prow["payload"] or {},
                              _spec_for(cur, prow["record_type"]))
            _refuse_on_cross_check(_cross_check_blockers(xc))
        cur.execute(
            "UPDATE staging.record SET row_status = 'verified', verified_by = %s, "
            "verified_at = %s WHERE parent_uid = %s AND row_status = 'pending'",
            (body.verified_by, datetime.now(timezone.utc), record_uid),
        )
        n = cur.rowcount
        conn.commit()
        return {"ok": True, "verified": n}


@app.delete("/api/record/{record_uid}")
def delete_record(record_uid: str):
    """Soft delete. The row stays so its record_uid keeps blocking a re-ingest
    of the same source record, which is the whole point of a derived uid."""
    with db() as conn, dictcur(conn) as cur:
        cur.execute(
            "UPDATE staging.record SET row_status = 'deleted' WHERE record_uid = %s",
            (record_uid,),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="No such record")
        conn.commit()
        return {"ok": True}


@app.post("/api/record/{record_uid}/party")
def set_record_party(record_uid: str, body: SetSupplierBody):
    """Confirming a party also teaches the alias register, so the next batch
    from any feed matches it without a flag."""
    with db() as conn, dictcur(conn) as cur:
        cur.execute("SELECT party_name FROM staging.record WHERE record_uid = %s", (record_uid,))
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="No such record")
        cur.execute("SELECT id, name FROM contacts.organisations WHERE id = %s",
                    (body.supplier_id,))
        org = cur.fetchone()
        if org is None:
            raise HTTPException(status_code=400, detail="No such organisation")

        if row["party_name"]:
            cur.execute(
                "INSERT INTO normalisation.supplier_aliases (alias_text, organisation_id) "
                "VALUES (%s,%s) ON CONFLICT (alias_text) DO UPDATE "
                "SET organisation_id = EXCLUDED.organisation_id",
                (row["party_name"], body.supplier_id),
            )
        cur.execute(
            "UPDATE staging.record SET party_id = %s, match_type = 'alias', "
            "match_score = NULL, candidate_name = NULL WHERE record_uid = %s",
            (body.supplier_id, record_uid),
        )
        conn.commit()
        return {"ok": True, "party_id": body.supplier_id, "party_name": org["name"]}


app.mount("/", StaticFiles(directory=BASE_DIR / "static", html=True), name="static")
