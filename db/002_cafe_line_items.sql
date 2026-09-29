-- ============================================================================
-- Bowerbird Verifier — migration 002
-- Run this against 115kws AFTER 001_verifier_schema.sql.
--
-- What this does and why:
--  1. Clears staging.cafe_invoices. It currently only holds the 6 fictional
--     demo rows (Bianco Coffee, Bakemart, etc.) from testing the UI scaffold
--     against sample data — nothing real has been staged yet, so this is
--     safe. If you've since loaded anything real in there, STOP and tell me
--     before running this.
--  2. Replaces the placeholder record_id/pdf_path columns with what the real
--     pipeline actually gives us: a `filename` (from the Invoice Summary
--     Pending.xlsx `filename` column), which is unique per document and
--     needs no separate resolution step. Adds `payment_status`, since the
--     real staging file already states it (Paid/Unpaid) rather than
--     defaulting everything to Unpaid.
--  3. Adds staging.cafe_purchases — the line-item review queue, one row per
--     line, linked to its parent invoice via invoice_staging_id.
-- ============================================================================

-- 1. Clear the fictional test rows.
TRUNCATE staging.cafe_invoices RESTART IDENTITY;

-- 2. Restructure staging.cafe_invoices around the real column set.
DROP INDEX IF EXISTS idx_staging_cafe_invoices_record_id;

ALTER TABLE staging.cafe_invoices
    DROP COLUMN IF EXISTS record_id,
    DROP COLUMN IF EXISTS pdf_path,
    DROP COLUMN IF EXISTS source_file,
    ADD COLUMN IF NOT EXISTS filename text,
    ADD COLUMN IF NOT EXISTS payment_status text DEFAULT 'Unpaid';

ALTER TABLE staging.cafe_invoices ALTER COLUMN filename SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_staging_cafe_invoices_filename
    ON staging.cafe_invoices (filename);

-- 3. Line-item staging table.
CREATE TABLE IF NOT EXISTS staging.cafe_purchases (
    staging_id        serial PRIMARY KEY,
    invoice_staging_id integer NOT NULL REFERENCES staging.cafe_invoices(staging_id) ON DELETE CASCADE,
    filename          text,   -- carried through for the PDF-link column; same file as the parent invoice
    purchase_date     date,
    category          text,
    item              text,
    qty               numeric,
    unit_cost         numeric,
    line_total        numeric,
    gst_applicable    boolean,
    gst_declared      numeric,
    gst_assessed      numeric,
    expense_type      text CHECK (expense_type IN ('COGS','Operating Expense','Non-Business','Capital')),
    surcharge_source  text CHECK (surcharge_source IS NULL OR surcharge_source IN ('Invoice','Bank derived')),
    in_invoice_total  boolean DEFAULT true,
    notes             text,

    row_status        text DEFAULT 'pending' CHECK (row_status IN ('pending','verified','deleted','imported')),
    verified_by       text,
    verified_at       timestamp,
    imported_at       timestamp,
    created_at        timestamp DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cafe_purchases_invoice_staging_id
    ON staging.cafe_purchases (invoice_staging_id);

-- Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON staging.cafe_purchases TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE staging.cafe_purchases_staging_id_seq TO verifier_app;
GRANT SELECT, INSERT ON cafe.purchases TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE cafe.purchase_orders_id_seq TO verifier_app;
GRANT SELECT ON cafe.expense_categories TO verifier_app;
