#!/bin/bash
# Bowerbird Verifier - launcher.
#
# Environment variables don't survive a new terminal window, and the app's
# built-in defaults point at kws115_TEST with auto-ingest switched off. Start
# it with this script instead of a bare uvicorn line and it can't silently
# come up against the wrong database again.
#
#   ./run.sh
#
# Paths come from staging_env.sh. The database URL, which carries a password,
# comes from .env.local and is deliberately not part of the app's source files.

set -euo pipefail
cd "$(dirname "$0")"

set -a
. ./staging_env.sh
if [ -f .env.local ]; then . ./.env.local; fi
set +a

if [ -z "${VERIFIER_DB_URL:-}" ]; then
  echo "ERROR: VERIFIER_DB_URL is not set." >&2
  echo "Create backend/.env.local containing:" >&2
  echo '  VERIFIER_DB_URL="postgresql://verifier_app:<password>@127.0.0.1:5432/kws115"' >&2
  exit 1
fi

case "$VERIFIER_DB_URL" in
  *kws115_test*) echo "WARNING: pointing at the TEST database, not kws115." >&2 ;;
esac

for v in VERIFIER_PDF_ROOT VERIFIER_INVOICE_SUMMARY_PATH VERIFIER_LINE_ITEMS_PATH VERIFIER_STAGING_INBOX; do
  if [ ! -e "${!v}" ]; then
    echo "WARNING: $v does not exist: ${!v}" >&2
  fi
done

echo "database  : ${VERIFIER_DB_URL##*@}"
echo "pdf root  : $VERIFIER_PDF_ROOT"
echo "staging   : $(dirname "$VERIFIER_INVOICE_SUMMARY_PATH")"
echo "inbox     : $VERIFIER_STAGING_INBOX"
echo

exec python3 -m uvicorn main:app --host 127.0.0.1 --port 8420 --loop asyncio --http h11
