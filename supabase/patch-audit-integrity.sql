-- ─── Patch: audit_logs can no longer be forged ──────────────────
-- audit_insert previously only checked `auth.uid() IS NOT NULL` — any
-- authenticated user could INSERT a row with an arbitrary user_id via
-- a direct REST call, forging e.g. "approved by [someone else]" in the
-- audit trail this app's own receipt/timeline UI treats as
-- authoritative. Every logAudit() call site in js/data/*.js already
-- sets user_id: session.user.id, so this was never actually needed for
-- any legitimate call.
--
-- Idempotent — safe to run more than once.

BEGIN;

DROP POLICY IF EXISTS "audit_insert" ON audit_logs;
CREATE POLICY "audit_insert" ON audit_logs
  FOR INSERT WITH CHECK (user_id = auth.uid());

COMMIT;
