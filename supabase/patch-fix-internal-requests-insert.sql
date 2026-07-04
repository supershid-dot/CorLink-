-- ============================================================
-- CorLink — Patch: fix internal_requests_insert ambiguous column bug
--
-- Run this INSTEAD of re-running the full rls.sql.
--
-- "Loop in a Section" (creating an internal_requests row) was failing
-- with "new row violates row-level security policy for table
-- internal_requests" for every request whose parent_request_id is
-- NULL (i.e. every root/original request — the common case).
--
-- Root cause: the policy's EXISTS subquery had
--   SELECT 1 FROM requests r WHERE r.id = parent_request_id
-- `requests` ALSO has a column literally named parent_request_id (used
-- for its own follow-up-request chaining), so the bare
-- `parent_request_id` reference silently resolved to the closer/inner
-- r.parent_request_id instead of the intended outer internal_requests
-- row being inserted — collapsing the check to "is this request its
-- own parent", which is NULL (not true) for a root request. Confirmed
-- empirically against a real Postgres instance before/after this fix.
--
-- Fix: qualify it explicitly as internal_requests.parent_request_id.
-- This bug has been present since Phase 6 (patch-phase6-workflow.sql)
-- shipped — this is the first fix for it.
-- ============================================================

BEGIN;

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
  );

COMMIT;
