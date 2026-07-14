-- ─── Patch: Cancel a Sent Request ────────────────────────────────
-- Lets the sender pull a request back any time before a response has
-- actually been sent — the original creator, or a supervisor of the
-- SENDING section. Cancelling is terminal (like 'closed') and freezes
-- the case at the database level, not just in the UI: no further
-- responses, and no further Internal Collaboration activity on it.
--
-- Bundles two incidental fixes found necessary while adding a reachable
-- 'cancelled' status (same pattern as patch-narrow-supervisor-
-- visibility.sql's own incidental cross-org fix):
--
-- 1. requests_update_supervisor (rls.sql) had NO WITH CHECK at all —
--    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
--    AND is_supervisor_or_above(), nothing scoping the OUTCOME of the
--    update. Once 'cancelled' becomes reachable this would let a
--    RECEIVING-org supervisor cancel a request too (Postgres ORs all
--    permissive policies together — a narrower policy added alongside
--    it doesn't subtract permission already granted by this one). Fixed
--    by adding a WITH CHECK that only restricts the 'cancelled' outcome
--    to from_org_id = get_my_org_id(); every other existing to-org-
--    supervisor transition through this policy (route/assign/approve-
--    response/close) is untouched.
--
-- 2. check_deadlines() (notifications.sql) flips past-deadline requests
--    to 'overdue' in a single PL/pgSQL loop with no transition edge out
--    of 'cancelled' (it's terminal). Without excluding 'cancelled' from
--    its WHERE clause, the first cancelled-and-overdue row it hits
--    would RAISE EXCEPTION and abort the ENTIRE nightly run, silently
--    breaking overdue-flagging for every other request that day. Fixed
--    by adding 'cancelled' to that exclusion list (this file re-applies
--    supabase/notifications.sql's own fix so a live DB that only runs
--    patch files, not the full notifications.sql, still gets it).
--
-- Idempotent — safe to run more than once, and safe to run before or
-- after patch-return-to-sender.sql (both converge on the same final
-- audit_logs.action CHECK list).

BEGIN;

-- ── Schema ────────────────────────────────────────────────────────
ALTER TABLE requests DROP CONSTRAINT IF EXISTS requests_status_check;
ALTER TABLE requests ADD CONSTRAINT requests_status_check CHECK (status IN (
  'draft', 'pending_approval', 'sent', 'received',
  'in_progress', 'responded', 'closed', 'overdue', 'cancelled'
));

ALTER TABLE requests ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES users(id);
ALTER TABLE requests ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check CHECK (action IN (
  'created', 'edited', 'submitted', 'approved', 'returned',
  'sent', 'received', 'routed', 'assigned',
  'returned_to_sender', 'cancelled',
  'extension_requested', 'extension_approved', 'extension_denied',
  'viewed', 'login', 'logout', 'login_failed', 'locked',
  'password_changed', 'user_created', 'user_deactivated'
));

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check CHECK (type IN (
  'new_request', 'new_response', 'approval_requested', 'draft_returned',
  'deadline_warning', 'extension_requested', 'extension_decided',
  'new_prisoner_letter', 'letter_replied',
  'new_external_correspondence', 'external_correspondence_replied',
  'request_cancelled'
));

-- ── Status transition graph ─────────────────────────────────────
CREATE OR REPLACE FUNCTION valid_request_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'pending_approval'),
    ('pending_approval', 'sent'),
    ('pending_approval', 'draft'),
    ('pending_approval', 'overdue'),
    ('sent', 'received'),
    ('sent', 'overdue'),
    ('received', 'in_progress'),
    ('received', 'overdue'),
    ('in_progress', 'responded'),
    ('in_progress', 'overdue'),
    ('responded', 'closed'),
    ('overdue', 'sent'),
    ('overdue', 'draft'),
    ('overdue', 'received'),
    ('overdue', 'in_progress'),
    ('overdue', 'responded'),
    -- Sender-initiated retraction, any time before a response is
    -- actually sent — terminal, no edge leads back out of 'cancelled'.
    ('sent', 'cancelled'),
    ('received', 'cancelled'),
    ('in_progress', 'cancelled'),
    ('overdue', 'cancelled')
  );
$$ LANGUAGE sql IMMUTABLE;

-- ── check_deadlines() fix (bug #2 above) ────────────────────────
CREATE OR REPLACE FUNCTION check_deadlines()
RETURNS void AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id, from_section_id, to_section_id, subject, deadline
    FROM requests
    WHERE deadline IS NOT NULL
      AND deadline < CURRENT_DATE
      AND status NOT IN ('draft', 'closed', 'responded', 'overdue', 'cancelled')
  LOOP
    UPDATE requests SET status = 'overdue' WHERE id = r.id;

    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'deadline_warning', 'request', r.id,
           'Request "' || r.subject || '" is overdue (deadline was ' || r.deadline || ')'
    FROM (
      SELECT user_id AS uid FROM section_user_ids(
        COALESCE(r.to_section_id, r.from_section_id),
        ARRAY['mcs_admin', 'authority_admin', 'supervisor']
      )
    ) recipients;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── RLS ──────────────────────────────────────────────────────────
-- Bug #1 fix: narrow requests_update_supervisor's outcome so a
-- receiving-org supervisor can't cancel — every other transition this
-- policy already allowed (route/assign/approve-response/close) is
-- untouched.
DROP POLICY IF EXISTS "requests_update_supervisor" ON requests;
CREATE POLICY "requests_update_supervisor" ON requests
  FOR UPDATE USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND is_supervisor_or_above()
  )
  WITH CHECK (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND is_supervisor_or_above()
    AND (status <> 'cancelled' OR from_org_id = get_my_org_id())
  );

-- New policy: creator or a supervisor of the SENDING section can cancel,
-- any time before a response has actually been sent. WITH CHECK is
-- deliberately asymmetric from USING's status list (requires exactly
-- status = 'cancelled') — a WITH CHECK that repeated USING's status
-- list would reject its own update, the same "USING reused as WITH
-- CHECK" trap already documented on requests_update/requests_update_
-- assigned_receiver elsewhere in this schema.
DROP POLICY IF EXISTS "requests_update_cancel" ON requests;
CREATE POLICY "requests_update_cancel" ON requests
  FOR UPDATE USING (
    from_org_id = get_my_org_id()
    AND status IN ('sent', 'received', 'in_progress', 'overdue')
    AND (created_by = auth.uid() OR (is_supervisor_or_above() AND from_section_id IN (SELECT my_section_ids())))
  )
  WITH CHECK (
    from_org_id = get_my_org_id()
    AND status = 'cancelled'
    AND (created_by = auth.uid() OR (is_supervisor_or_above() AND from_section_id IN (SELECT my_section_ids())))
  );

-- Freeze a cancelled case uniformly: no new responses, no new internal-
-- collab activity, no further internal-reply drafting/approval — same
-- "RLS is the real gate" convention this app already uses for is_locked
-- freezing attachments once a request/response is sent.
DROP POLICY IF EXISTS "responses_insert" ON responses;
CREATE POLICY "responses_insert" ON responses
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND r.to_org_id = get_my_org_id()
        AND r.status <> 'cancelled'
    )
  );

DROP POLICY IF EXISTS "responses_update" ON responses;
CREATE POLICY "responses_update" ON responses
  FOR UPDATE USING (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = request_id AND r.status <> 'cancelled')
  )
  WITH CHECK (
    created_by = auth.uid()
    AND is_locked = FALSE
    AND status IN ('draft', 'pending_approval')
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = request_id AND r.status <> 'cancelled')
  );

DROP POLICY IF EXISTS "responses_update_supervisor" ON responses;
CREATE POLICY "responses_update_supervisor" ON responses
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND r.status <> 'cancelled'
    )
    AND is_supervisor_or_above()
  );

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
        AND r.status <> 'cancelled'
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

DROP POLICY IF EXISTS "internal_requests_update" ON internal_requests;
CREATE POLICY "internal_requests_update" ON internal_requests
  FOR UPDATE USING (
    (
      to_section_id IN (SELECT my_section_ids())
      OR from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
    )
    -- Frozen once the parent request is cancelled — no further Mark
    -- Received/Assign/Reroute/Close/Return to Sender, matching how
    -- is_locked already freezes attachments on a sent request/response.
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = parent_request_id AND r.status <> 'cancelled')
  );

DROP POLICY IF EXISTS "internal_request_replies_insert" ON internal_request_replies;
CREATE POLICY "internal_request_replies_insert" ON internal_request_replies
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      JOIN requests r ON r.id = ir.parent_request_id
      WHERE ir.id = internal_request_id
        AND ir.to_section_id IN (SELECT my_section_ids())
        AND r.status <> 'cancelled'
    )
  );

DROP POLICY IF EXISTS "internal_request_replies_update" ON internal_request_replies;
CREATE POLICY "internal_request_replies_update" ON internal_request_replies
  FOR UPDATE USING (
    (
      (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
      OR EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
          AND is_supervisor_or_above()
          AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      )
    )
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      JOIN requests r ON r.id = ir.parent_request_id
      WHERE ir.id = internal_request_id AND r.status <> 'cancelled'
    )
  )
  WITH CHECK (
    (
      (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
      OR EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
          AND is_supervisor_or_above()
          AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      )
    )
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      JOIN requests r ON r.id = ir.parent_request_id
      WHERE ir.id = internal_request_id AND r.status <> 'cancelled'
    )
  );

COMMIT;
