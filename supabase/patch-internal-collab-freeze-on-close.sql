-- ─── Patch: freeze "Loop in a Section" once the case is done ───
-- internal_requests_insert's WITH CHECK only blocked starting a new
-- internal collaboration round on a CANCELLED case — a closed or
-- responded case still let the assignee start a brand-new "Loop in a
-- Section" round, which has no reason to exist once the case is done
-- (closed cases show only "Case closed"; responded ones are just
-- awaiting acknowledge-and-close). The "Loop in a Section" button was
-- visible in the UI on a closed case, reflecting this real gap, not
-- just a cosmetic miss.
--
-- Narrower than internal_requests_update on purpose: an internal_request
-- already IN FLIGHT when the case reaches one of these statuses stays
-- updatable there (via internal_requests_update, unchanged) so it can
-- still be finished — only NEW ones are blocked.
--
-- Idempotent: DROP POLICY IF EXISTS + CREATE POLICY, safe to re-run.

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
        AND r.status NOT IN ('cancelled', 'closed', 'responded')
    )
    AND (
      internal_requests.deadline IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id
          AND r.deadline IS NOT NULL AND internal_requests.deadline > r.deadline
      )
    )
  );
