-- ============================================================================
-- Bowerbird Verifier — migration 003
-- Run this against 115kws AFTER 001 and 002.
--
-- The new supplier picker (search contacts.organisations, or register a new
-- one) needs the app's role to actually write there, not just read it.
-- ============================================================================

GRANT INSERT, UPDATE ON contacts.organisations TO verifier_app;
GRANT USAGE, SELECT ON SEQUENCE contacts.organisations_id_seq TO verifier_app;

-- Confirming a supplier via the picker UPSERTs an alias (INSERT ... ON
-- CONFLICT DO UPDATE) - the UPDATE half of that was missing; 001 only
-- granted INSERT.
GRANT UPDATE ON normalisation.supplier_aliases TO verifier_app;
