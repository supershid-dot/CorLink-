-- ============================================================
-- CorLink — Patch: disable attachments after request/response approval
--
-- Run this INSTEAD of re-running the full rls.sql.
--
-- Once a request/response is is_locked (set on supervisor approval),
-- the upload dropzone is now hidden client-side — this patch makes
-- that a real server-side restriction too, matching the "buttons are
-- UX only, RLS is the real gate" convention this app already follows
-- everywhere else. Existing attachments remain visible/downloadable;
-- only new INSERTs against a locked record are blocked.
--
-- internal_request has no approval/lock concept, so it's unrestricted
-- there — but that branch still requires record_id to resolve to a
-- REAL internal_requests row (mirroring attachments_select's own
-- shape), not a bare `record_type = 'internal_request'` escape hatch:
-- attachments.record_id has no FK tying it to whichever table
-- record_type implies, so without this EXISTS check, record_type
-- could be spoofed as 'internal_request' while record_id is actually
-- a LOCKED request's/response's id, bypassing the lock check entirely
-- (caught in code review before this ever shipped).
--
-- No new columns — this is RLS-only, safe to re-run.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND NOT EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id AND r.is_locked
      ))
      OR (record_type = 'response' AND NOT EXISTS (
        SELECT 1 FROM responses re WHERE re.id = record_id AND re.is_locked
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
      ))
    )
  );

COMMIT;
