-- ─── Patch: index internal_requests + prisoner_letters filter columns ──
-- Same root cause as patch-participant-column-indexes.sql (the recurring
-- request-detail statement-timeout fix), just not yet triggered on these
-- two tables because they stay smaller than requests/responses early on.
--
-- internal_requests_select's RLS (rls.sql) filters on from_section_id,
-- to_section_id, previous_section_id and created_by; listOutstandingFor
-- Sections/listAssignedToUser (internal-requests-api.js) filter on
-- from_section_id/to_section_id/status and assigned_to respectively.
-- Only parent_request_id was indexed — every other filter was a
-- sequential scan that gets slower as the table grows.
--
-- prisoner_letters.listInbox (prisoner-letters-api.js) filters on
-- to_org_id — from_prison_id (listSent's filter) was already indexed,
-- to_org_id wasn't.
--
-- Idempotent: CREATE INDEX IF NOT EXISTS.

CREATE INDEX IF NOT EXISTS idx_internal_requests_from_section     ON internal_requests(from_section_id);
CREATE INDEX IF NOT EXISTS idx_internal_requests_to_section       ON internal_requests(to_section_id);
CREATE INDEX IF NOT EXISTS idx_internal_requests_status           ON internal_requests(status);
CREATE INDEX IF NOT EXISTS idx_internal_requests_assigned_to      ON internal_requests(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_internal_requests_created_by       ON internal_requests(created_by);
CREATE INDEX IF NOT EXISTS idx_internal_requests_previous_section ON internal_requests(previous_section_id) WHERE previous_section_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_prisoner_letters_to_org ON prisoner_letters(to_org_id);
