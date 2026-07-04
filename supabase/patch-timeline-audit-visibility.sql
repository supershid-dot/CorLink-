-- ============================================================
-- CorLink — Patch: case timeline visibility for audit_logs + users
--
-- Run this INSTEAD of re-running the full rls.sql.
--
-- request-detail.js's conversation view now renders "Routed to X by Y
-- — [time]" / "Assigned to X by Y — [time]" inline in the thread,
-- reusing the audit_logs rows logAudit() already writes on every
-- routeRequest()/assignRequest() call. The existing audit_select
-- policy only lets org admins read audit_logs (it's scoped to the
-- admin-only global Audit Log tab) — this adds:
--
--  1. can_view_case_audit_record(record_type, record_id) — a shared
--     helper so the two policies below can't silently drift apart.
--     Deliberately covers every action type on a request/response, not
--     just routed/assigned (see the function's own comment).
--  2. audit_select_own_records — lets anyone who can already SEE a
--     given request/response also see its audit trail entries.
--  3. users_select_audit_trail — without this, the "by [Name]" half of
--     the timeline silently shows "by Unknown" for a cross-org actor
--     (e.g. the destination org's supervisor who routed the request),
--     since the pre-existing users_select_correspondence policy only
--     covers a request/response's own created_by/assigned_to/
--     received_by/reviewed_by, not "whoever performed a given
--     workflow action."
--
-- No new columns — this is RLS-only, safe to re-run.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION can_view_case_audit_record(p_record_type TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp
      JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR resp.created_by   = auth.uid()
          OR resp.received_by  = auth.uid()
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "audit_select_own_records" ON audit_logs;
CREATE POLICY "audit_select_own_records" ON audit_logs
  FOR SELECT USING (can_view_case_audit_record(record_type, record_id));

-- Its own SECURITY DEFINER function, not an EXISTS(...) inlined into
-- the policy below — that would run under the invoking role, re-
-- triggering audit_logs's own RLS (audit_select queries `users`, which
-- would re-evaluate users_select_audit_trail, which queries
-- audit_logs again — "infinite recursion detected in policy for
-- relation audit_logs", hit for real against a local Postgres instance
-- before adding this wrapper). SECURITY DEFINER breaks the cycle the
-- same way every other helper in rls.sql already does for
-- user_assignments: it runs as the function owner, bypassing RLS,
-- instead of re-entering audit_logs'/users' own policies.
CREATE OR REPLACE FUNCTION appears_in_visible_audit_trail(p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM audit_logs al
    WHERE al.user_id = p_user_id
      AND can_view_case_audit_record(al.record_type, al.record_id)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "users_select_audit_trail" ON users;
CREATE POLICY "users_select_audit_trail" ON users
  FOR SELECT USING (appears_in_visible_audit_trail(users.id));

COMMIT;
