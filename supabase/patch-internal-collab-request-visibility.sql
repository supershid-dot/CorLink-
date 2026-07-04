-- ============================================================
-- CorLink — Patch: let a looped-in section view the parent case
--
-- Run this INSTEAD of re-running the full rls.sql.
--
-- A section looped in via internal_requests ("Loop in a Section")
-- wasn't necessarily the request's own from/to section, creator, or
-- receiver — so requests_select never granted it visibility into the
-- case it was asked to help with. Two concrete symptoms this fixed:
--   1. The Info Requests tab's "Case" column always showed "—"
--      (PostgREST's embedded `parent_request:requests!...` join
--      silently returns null when RLS blocks the embedded row).
--   2. Its "View" button linked to #request-detail?id=undefined,
--      which then failed with "invalid input syntax for type uuid:
--      undefined".
--
-- Scoped narrowly to exactly the request(s) a section was actually
-- looped into, not every request in that org.
--
-- looped_in_via_internal_collab() is its own SECURITY DEFINER
-- function rather than an EXISTS(...) inlined into the policy —
-- internal_requests_insert's own WITH CHECK queries `requests`, so a
-- plain subquery here referencing internal_requests would run under
-- the invoking role and re-trigger internal_requests' policies, which
-- circle back to requests — "infinite recursion detected in policy
-- for relation internal_requests", confirmed empirically against a
-- local Postgres instance before adding this wrapper. SECURITY
-- DEFINER runs as the function owner, bypassing RLS, instead of
-- re-entering the other table's policies.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION looped_in_via_internal_collab(p_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.parent_request_id = p_request_id
      AND ir.to_section_id IN (SELECT my_section_ids())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "requests_select_via_internal_collab" ON requests;
CREATE POLICY "requests_select_via_internal_collab" ON requests
  FOR SELECT USING (looped_in_via_internal_collab(requests.id));

COMMIT;
