#!/bin/bash
# Non-secret paths shared by the app and the staging CLI tools.
# run.sh sources this. Source it yourself before running shim_invoice_staging.py
# or staging_ingest.py by hand:
#
#   cd ~/Desktop/Finance\ and\ Data/Apps/verifier-app/backend
#   set -a; . ./staging_env.sh; . ./.env.local; set +a
#
# The database URL is NOT here. It lives in .env.local, which holds a password.

FD="/Users/admin/Desktop/Finance and Data"

export VERIFIER_PDF_ROOT="${VERIFIER_PDF_ROOT:-/Users/admin/Desktop/INBOX TO FILE}"
# Folders searched (by file name) for a record's source PDF, colon-separated. Add the folder(s) invoices are filed in.
export VERIFIER_PDF_ROOTS="${VERIFIER_PDF_ROOTS:-$VERIFIER_PDF_ROOT}"
export VERIFIER_INVOICE_SUMMARY_PATH="${VERIFIER_INVOICE_SUMMARY_PATH:-$FD/Invoice Staging/Invoice Summary - Pending.xlsx}"
export VERIFIER_LINE_ITEMS_PATH="${VERIFIER_LINE_ITEMS_PATH:-$FD/Invoice Staging/Cafe Line Items - Pending.xlsx}"

export VERIFIER_STAGING_INBOX="${VERIFIER_STAGING_INBOX:-$FD/Staging Inbox}"
export VERIFIER_STAGING_PROCESSED="${VERIFIER_STAGING_PROCESSED:-$FD/Staging Inbox/Processed}"
export VERIFIER_STAGING_REJECTED="${VERIFIER_STAGING_REJECTED:-$FD/Staging Inbox/Rejected}"

# Payroll. The PDF archive is the durable record of what IPS was told to pay;
# Time Record.xlsx holds only the current week and is overwritten, so it is
# deliberately not listed here. The ledger is written by the Friday scheduled
# task and is the Square side of the comparison.
export VERIFIER_PAYROLL_PDF_DIR="${VERIFIER_PAYROLL_PDF_DIR:-$FD/Payroll}"
export VERIFIER_PAYROLL_LEDGER="${VERIFIER_PAYROLL_LEDGER:-$FD/Payroll/Payroll_Outputs/payroll_ledger.jsonl}"
