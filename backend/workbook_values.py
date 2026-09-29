"""
workbook_values.py - turning spreadsheet cells into values JSON can hold.

Extracted verbatim from shim_invoice_staging.py. Only producers that read
workbooks need these; the envelope itself does not, which is why they are not
in staging_envelope.py - importing pandas to write a JSONL file would be a
dependency for nothing.

Each of these carries a fix that cost something to find. Read the comments
before simplifying any of them.
"""

import datetime as dt
import math

import pandas as pd

def clean(value):
    """Excel value to something JSON can hold, without inventing anything."""
    if value is None:
        return None
    if isinstance(value, float) and math.isnan(value):
        return None
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    if hasattr(value, "date"):
        return value.date().isoformat()
    if isinstance(value, dt.date):
        return value.isoformat()
    if hasattr(value, "item"):
        value = value.item()
    if isinstance(value, str):
        # Untrimmed cells are routine in these workbooks, and a trailing space
        # defeats both the duplicate guard at promotion and the UNIQUE index in
        # accounting.invoices - so a real duplicate would land.
        value = value.strip()
        return value or None
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value

def as_text(value):
    """For a column the destination stores as text. An all-digit identifier
    read as a number must not reach the payload as one."""
    value = clean(value)
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value).strip() or None

def to_bool(value):
    value = clean(value)
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    # pandas upcasts a boolean column that also holds blank cells to float64,
    # so a cell containing TRUE arrives as 1.0. Compare numerically first.
    # clean() happens to turn 1.0 into 1 and so got the right answer by
    # accident; this makes it deliberate.
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() in ("true", "yes", "1", "y", "t")
