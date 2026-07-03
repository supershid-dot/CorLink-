-- ============================================================
-- CorLink — Patch: independent subject/body language + editable
-- drafts through pending_approval
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql.
--
-- Part 1 — subject_language column
-- Subject and body can now each be written in a different language
-- (the compose form gives them independent EN/Dhivehi toggles), so the
-- display language of each is tracked separately instead of sharing
-- the single `language` column, which stays as the body's language.
--
-- Part 2 — requests_update / responses_update RLS fix
-- These policies previously gated on `status = 'draft'` with no
-- explicit WITH CHECK. Postgres reuses the USING expression as the
-- WITH CHECK when one isn't given, so the very update submitRequest()/
-- submitResponse() perform (draft -> pending_approval) always violated
-- its own policy's implied check — "Submit for Approval" has been
-- silently broken for every non-supervisor creator. Fixed by widening
-- the allowed status range to include pending_approval (so staff can
-- also keep editing a draft while it's awaiting approval, not just
-- before submitting it) and adding an explicit WITH CHECK that still
-- excludes 'sent'/'received'/etc — a creator still can't use this
-- policy to self-approve by skipping requests_update_supervisor.
-- Verified against a real local Postgres instance: submit-for-approval
-- now succeeds, editing while pending_approval succeeds, a direct
-- status='sent' write by the creator is rejected, the supervisor
-- approval path is unaffected, and edit access is cut off the moment
-- status actually becomes 'sent'.
-- ============================================================

BEGIN;

ALTER TABLE requests
  ADD COLUMN IF NOT EXISTS subject_language TEXT NOT NULL DEFAULT 'en'
    CHECK (subject_language IN ('en', 'dv'));

ALTER TABLE internal_requests
  ADD COLUMN IF NOT EXISTS subject_language TEXT NOT NULL DEFAULT 'en'
    CHECK (subject_language IN ('en', 'dv'));

DROP POLICY IF EXISTS "requests_update" ON requests;
CREATE POLICY "requests_update" ON requests
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status   IN ('draft', 'pending_approval')
  )
  WITH CHECK (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status   IN ('draft', 'pending_approval')
  );

DROP POLICY IF EXISTS "responses_update" ON responses;
CREATE POLICY "responses_update" ON responses
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
  )
  WITH CHECK (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
  );

COMMIT;
