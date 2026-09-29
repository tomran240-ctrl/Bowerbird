-- Local test replica only — mirrors the EXISTING production tables so the
-- new code can be tested end-to-end before touching the real database.

CREATE SCHEMA IF NOT EXISTS normalisation;
CREATE SCHEMA IF NOT EXISTS contacts;
CREATE SCHEMA IF NOT EXISTS cafe;
CREATE SCHEMA IF NOT EXISTS accounting;
CREATE SCHEMA IF NOT EXISTS maintenance;
CREATE SCHEMA IF NOT EXISTS leasing;

CREATE TABLE normalisation.properties (
    property_code text PRIMARY KEY,
    property_name text
);
INSERT INTO normalisation.properties VALUES
    ('115KW','115 King William Street'),
    ('117KW','117 King William Street');

CREATE TABLE contacts.organisations (
    id serial PRIMARY KEY,
    org_number text,
    name text NOT NULL
);
INSERT INTO contacts.organisations (name) VALUES
    ('Bianco Coffee Co'),
    ('Bakemart Supplies'),
    ('Zesty Fresh Pty Ltd'),
    ('Coopers Brewery Limited'),
    ('Ordermentum Pty Ltd');

CREATE TABLE cafe.invoices (
    id serial PRIMARY KEY,
    property_code text NOT NULL REFERENCES normalisation.properties(property_code),
    supplier_id integer REFERENCES contacts.organisations(id),
    supplier_name text NOT NULL,
    invoice_number text NOT NULL,
    invoice_date date NOT NULL,
    payment_status text NOT NULL DEFAULT 'Unpaid'
        CHECK (payment_status IN ('Unpaid','Paid','Partially Paid','Disputed')),
    paid_date date,
    reconciled boolean NOT NULL DEFAULT false,
    reconciled_at timestamptz,
    source_file text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    amount_ex_gst numeric,
    gst_amount numeric,
    amount_inc_gst numeric,
    UNIQUE (supplier_name, invoice_number)
);

CREATE TABLE cafe.expense_categories (
    category text PRIMARY KEY,
    expense_type text NOT NULL,
    notes text
);
INSERT INTO cafe.expense_categories (category, expense_type) VALUES
    ('Cafe - Adjustment','Operating Expense'),
    ('Cafe - Bakery','COGS'),
    ('Cafe - Bank/Card Fees','Operating Expense'),
    ('Cafe - Beverage','COGS'),
    ('Cafe - Cakes - Biscuits','COGS'),
    ('Cafe - Card Surcharge','Operating Expense'),
    ('Cafe - Cleaning Supplies','Operating Expense'),
    ('Cafe - Coffee - Tea - Matcha','COGS'),
    ('Cafe - Dairy','COGS'),
    ('Cafe - Delivery Fees','Operating Expense'),
    ('Cafe - Food','COGS'),
    ('Cafe - GST Free - Soft Drinks','COGS'),
    ('Cafe - GST Free - Water','COGS'),
    ('Cafe - Grocery (ad hoc)','COGS'),
    ('Cafe - Linen','Operating Expense'),
    ('Cafe - Packaging','Operating Expense'),
    ('Cafe - Pantry','COGS'),
    ('Cafe - Recruitment','Operating Expense'),
    ('Cafe - Smoothies - Milkshakes','COGS'),
    ('Cafe - Soft Drinks','COGS'),
    ('Cafe - Subscriptions','Operating Expense'),
    ('Cafe - Supplies','Operating Expense'),
    ('Cafe - Too Good To Go Fees','COGS');

CREATE TABLE cafe.purchases (
    id serial PRIMARY KEY,
    property_code text NOT NULL REFERENCES normalisation.properties(property_code),
    supplier_id integer REFERENCES contacts.organisations(id),
    supplier_name text NOT NULL,
    purchase_date date NOT NULL,
    category text,
    item text NOT NULL,
    qty numeric CHECK (qty IS NULL OR qty >= 0),
    unit_cost numeric CHECK (unit_cost IS NULL OR unit_cost >= -1000),
    line_total numeric CHECK (line_total IS NULL OR line_total >= -1000),
    notes text,
    source text NOT NULL DEFAULT 'CAFE_PURCHASE_DB',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    invoice_number text,
    gst_applicable boolean,
    gst_assessed numeric CHECK (gst_assessed IS NULL OR gst_assessed >= 0),
    expense_type text CHECK (expense_type IN ('COGS','Operating Expense','Non-Business','Capital')),
    invoice_id integer REFERENCES cafe.invoices(id),
    gst_declared numeric,
    gst_status text CHECK (gst_status IN ('Auto','Confirmed','Corrected','Variance')),
    gst_reviewed_at timestamptz,
    surcharge_source text CHECK (surcharge_source IS NULL OR surcharge_source IN ('Invoice','Bank derived')),
    in_invoice_total boolean NOT NULL DEFAULT true,
    CONSTRAINT purchases_invoice_id_required CHECK (
        invoice_id IS NOT NULL OR source = 'CAFE_PURCHASE_DB' OR source LIKE 'Bank reconciliation%' OR source = 'manual - TGTG statement'
    ),
    CONSTRAINT purchases_gst_flag_consistent CHECK (NOT (gst_applicable IS FALSE AND COALESCE(gst_assessed,0) != 0)),
    CONSTRAINT purchases_surcharge_source_category CHECK (surcharge_source IS NULL OR category IN ('Cafe - Card Surcharge','Cafe - Adjustment')),
    CONSTRAINT purchases_outside_total_is_surcharge CHECK (in_invoice_total OR category IN ('Cafe - Card Surcharge','Cafe - Adjustment'))
);
