-- ============================================================
-- CorLink — Patch: close RLS gaps in the requests/approvals/
-- attachments policies ahead of Phase 3 (Requests & Responses).
--
-- Run this INSTEAD of re-running the full rls.sql — it only touches
-- the three policies below.
--
-- 1. requests_update_supervisor had no role check at all beyond "your
--    org is party to this request" — any staff member could set
--    status/reference_number/is_locked directly and skip the approval
--    workflow entirely. Now requires is_supervisor_or_above().
-- 2. approvals_select didn't let a request/response's own creator see
--    its approval history (was reviewed_by/is_admin() only).
-- 3. attachments_select required supervisor rank to view a file you
--    didn't upload yourself, even if you could otherwise see the
--    parent request/response — now mirrors that record's visibility.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "requests_update_supervisor" ON requests;
CREATE POLICY "requests_update_supervisor" ON requests
  FOR UPDATE USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND is_supervisor_or_above()
  );

DROP POLICY IF EXISTS "approvals_select" ON approvals;
CREATE POLICY "approvals_select" ON approvals
  FOR SELECT USING (
    reviewed_by = auth.uid() OR is_admin()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.created_by = auth.uid()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re WHERE re.id = record_id AND re.created_by = auth.uid()
    ))
  );

DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR is_supervisor_or_above()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
  );

COMMIT;
