-- ============================================================================
-- Bowerbird Verifier — schema additions for 115kws
-- Run this once against the real database (TablePlus, psql, etc).
-- ============================================================================

-- 1. Supplier alias lookup — learns over time as flagged matches get confirmed
CREATE TABLE IF NOT EXISTS normalisation.supplier_aliases (
    id              serial PRIMARY KEY,
    alias_text      text NOT NULL,
    organisation_id integer NOT NULL REFERENCES contacts.organisations(id),
    created_at      timestamp DEFAULT now(),
    UNIQUE (alias_text)
);

-- needed for fuzzy supplier-name matching (trigram similarity)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_organisations_name_trgm
    ON contacts.organisations USING gin (name gin_trgm_ops);

-- 2. Staging schema + café invoices staging table
CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.cafe_invoices (
    staging_id           serial PRIMARY KEY,
    record_id            text,
    pdf_path             text,
    supplier_name        text,
    supplier_id          integer,
    invoice_number       text,
    invoice_date         date,
    amount_ex_gst        numeric,
    gst_amount           numeric,
    amount_inc_gst       numeric,
    source_file          text,
    notes                text,

    -- supplier-match bookkeeping (see normalisation.supplier_aliases)
    match_type           text CHECK (match_type IN ('alias','exact','fuzzy','none')),
    match_score          numeric,
    candidate_name        text,
    flagged              boolean GENERATED ALWAYS AS (match_type IS DISTINCT FROM 'alias') STORED,

    row_status           text DEFAULT 'pending' CHECK (row_status IN ('pending','verified','deleted','imported')),
    verified_by          text,
    verified_at          timestamp,
    imported_at          timestamp,

    created_at           timestamp DEFAULT now()
);

-- Defense-in-depth: the same record_id should never be ingested twice into
-- the pending queue (ingest_csv.py also checks this in Python, but a DB
-- constraint catches it even if two ingests race).
CREATE UNIQUE INDEX IF NOT EXISTS idx_staging_cafe_invoices_record_id
    ON staging.cafe_invoices (record_id) WHERE record_id IS NOT NULL;

-- Least-privilege grants for the app's own Postgres role.
-- Replace 'verifier_app' with whatever role you actually create for it.
GRANT USAGE ON SCHEMA staging TO verifier_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON staging.cafe_invoices TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE staging.cafe_invoices_staging_id_seq TO verifier_app;

GRANT USAGE ON SCHEMA normalisation TO verifier_app;
GRANT SELECT, INSERT ON normalisation.supplier_aliases TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE normalisation.supplier_aliases_id_seq TO verifier_app;
GRANT SELECT ON normalisation.properties TO verifier_app;

GRANT USAGE ON SCHEMA contacts TO verifier_app;
GRANT SELECT ON contacts.organisations TO verifier_app;

GRANT USAGE ON SCHEMA cafe TO verifier_app;
GRANT SELECT, INSERT ON cafe.invoices TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE cafe.invoices_id_seq TO verifier_app;
