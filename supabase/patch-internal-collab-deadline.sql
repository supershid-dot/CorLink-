-- ─── Patch: Internal Collaboration deadline (capped at parent) ──
-- "Loop in a Section" now lets the sender set a deadline for the
-- section it's asking — capped at the parent request's own deadline
-- (enforced server-side too, not just in the compose form's date
-- picker `max`, since a typed-in date or a days-derived date can
-- still bypass a client-side-only check).
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE internal_requests ADD COLUMN IF NOT EXISTS deadline DATE;

DROP POLICY IF EXISTS "internal_requests_insert" ON internal_requests;
CREATE POLICY "internal_requests_insert" ON internal_requests
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND (
      from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND scope_org_id('section', from_section_id) = get_my_org_id())
    )
    AND scope_org_id('section', to_section_id) = get_my_org_id()
    AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    -- A section gathering supporting info can't give itself more time
    -- than the case itself has — no cap if either deadline is unset.
    AND (
      internal_requests.deadline IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
          AND r.deadline IS NOT NULL AND internal_requests.deadline > r.deadline
      )
    )
  );

COMMIT;
