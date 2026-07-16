-- ─── Patch: "Mark as Received" for entries routed to a section ────
-- Once an entry is routed to a section, that section should be able to
-- explicitly mark it as received — recording who and when, the same
-- receipt-style step already used for requests/responses/internal_
-- requests (received_by/received_at). Distinct from the pre-existing
-- received_date column, which just records when the correspondence
-- itself physically/digitally arrived (set once, at logging time).
--
-- No RLS changes needed: external_correspondence_update_section
-- already grants the receiving section unrestricted UPDATE on any
-- column of a row routed to them.
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE external_correspondence ADD COLUMN IF NOT EXISTS received_by UUID REFERENCES users(id);
ALTER TABLE external_correspondence ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ;

COMMIT;
