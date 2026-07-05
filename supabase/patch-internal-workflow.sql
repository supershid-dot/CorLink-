-- ─── Patch: Internal Collaboration full workflow ────────────────
-- Brings internal requests up to the same lifecycle as external
-- correspondence: receive -> assign to staff -> draft reply ->
-- submit for approval -> supervisor approves & sends.
--
-- Run this against an existing database that was set up before this
-- change; fresh installs get all of it from schema.sql + rls.sql.
-- Idempotent — safe to run more than once.

BEGIN;

-- 1. internal_requests: assignment + the in_progress status
ALTER TABLE internal_requests ADD COLUMN IF NOT EXISTS assigned_to UUID REFERENCES users(id);

ALTER TABLE internal_requests DROP CONSTRAINT IF EXISTS internal_requests_status_check;
ALTER TABLE internal_requests ADD CONSTRAINT internal_requests_status_check
  CHECK (status IN ('sent', 'received', 'in_progress', 'responded', 'closed'));

-- 2. internal_request_replies: draft/approval workflow columns.
--    DEFAULT 'sent' keeps every pre-existing reply (they were all
--    sent instantly under the old flow) valid without a backfill.
ALTER TABLE internal_request_replies ADD COLUMN IF NOT EXISTS language TEXT NOT NULL DEFAULT 'en';
ALTER TABLE internal_request_replies DROP CONSTRAINT IF EXISTS internal_request_replies_language_check;
ALTER TABLE internal_request_replies ADD CONSTRAINT internal_request_replies_language_check
  CHECK (language IN ('en', 'dv'));

ALTER TABLE internal_request_replies ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'sent';
ALTER TABLE internal_request_replies DROP CONSTRAINT IF EXISTS internal_request_replies_status_check;
ALTER TABLE internal_request_replies ADD CONSTRAINT internal_request_replies_status_check
  CHECK (status IN ('draft', 'pending_approval', 'sent'));

ALTER TABLE internal_request_replies ADD COLUMN IF NOT EXISTS pending_approval_by UUID REFERENCES users(id);
ALTER TABLE internal_request_replies ADD COLUMN IF NOT EXISTS approved_by UUID REFERENCES users(id);
ALTER TABLE internal_request_replies ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;

-- 3. RLS: hide draft/pending replies from the asking side, and allow
--    the draft -> pending_approval -> sent transitions.
DROP POLICY IF EXISTS "internal_request_replies_select" ON internal_request_replies;
CREATE POLICY "internal_request_replies_select" ON internal_request_replies
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR internal_request_replies.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            internal_request_replies.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    )
  );

DROP POLICY IF EXISTS "internal_request_replies_update" ON internal_request_replies;
CREATE POLICY "internal_request_replies_update" ON internal_request_replies
  FOR UPDATE USING (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND is_supervisor_or_above()
        AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
    )
  )
  WITH CHECK (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND is_supervisor_or_above()
        AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
    )
  );

COMMIT;
