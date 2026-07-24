-- ─── Patch: Meeting Minutes (docs/22 Phase B, docs/23 §Phase B) ────
-- Requires patch-meetings-foundation.sql, patch-meetings-rsvp.sql, and
-- patch-meetings-attendance.sql already applied. Implements only the
-- meeting-minutes portion of docs/23's Phase B specification —
-- deliberately does NOT include personal participant notes or the
-- meeting lock feature (both remain unimplemented; neither
-- meetings.is_locked nor meeting_participants.personal_notes exists
-- after this patch). Minutes are a per-meeting field (not per-
-- participant), viewable by anyone who can already view the meeting
-- (meetings_select is unchanged), editable only by a meeting manager,
-- and finalizable by a supervisor-or-above, after which only an org
-- admin (within their own org) or a super admin may still edit them.
-- Idempotent — safe to re-run.
BEGIN;

-- ─── 1. meetings: minutes columns ───────────────────────────────
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS minutes TEXT;
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS minutes_finalized BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS minutes_updated_by UUID REFERENCES users(id);
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS minutes_updated_at TIMESTAMPTZ;

ALTER TABLE meetings DROP CONSTRAINT IF EXISTS meetings_minutes_finalized_requires_minutes_check;
ALTER TABLE meetings ADD CONSTRAINT meetings_minutes_finalized_requires_minutes_check
  CHECK (minutes_finalized = FALSE OR minutes IS NOT NULL);

-- ─── 2. update_minutes() RPC ─────────────────────────────────────
-- SECURITY DEFINER, search_path pinned, actor from auth.uid() only —
-- same convention as every other Meetings RPC. can_manage_meeting()
-- normally (creator, or org supervisor/admin, or super admin, exactly
-- as it already governs every other meeting mutation). Once
-- minutes_finalized, the population narrows to org admin (within
-- their own org) or super admin only — a plain creator/supervisor can
-- no longer edit finalized minutes, matching docs/23's specification
-- exactly.
CREATE OR REPLACE FUNCTION update_minutes(
  p_meeting_id UUID,
  p_minutes TEXT
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_minutes requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot update minutes on a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF v_meeting.minutes_finalized THEN
    IF NOT (is_super_admin() OR (is_admin() AND v_meeting.organization_id = get_my_org_id())) THEN
      RAISE EXCEPTION 'Minutes have been finalized — only an organization administrator or super administrator may edit them now';
    END IF;
  ELSE
    IF NOT can_manage_meeting(p_meeting_id) THEN
      RAISE EXCEPTION 'Not authorized to edit minutes for this meeting';
    END IF;
  END IF;

  UPDATE meetings SET
    minutes = p_minutes,
    minutes_updated_by = v_actor,
    minutes_updated_at = now()
    WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'minutes_updated', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. finalize_minutes() RPC ───────────────────────────────────
-- Supervisor-or-above (scoped to the meeting's own org — is_supervisor_
-- or_above() already resolves against the caller's own org membership,
-- and a non-super-admin caller can only ever reach a meeting in their
-- own org via can_view_meeting() in the first place, the same
-- simplification already relied on throughout this module) or super
-- admin. Requires non-blank minutes to already exist — finalizing an
-- empty/never-written minutes field would otherwise violate the
-- meetings_minutes_finalized_requires_minutes_check CHECK constraint
-- with an unfriendly generic error; this RPC raises a clear one first.
CREATE OR REPLACE FUNCTION finalize_minutes(
  p_meeting_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'finalize_minutes requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot finalize minutes on a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF NOT (is_super_admin() OR (is_supervisor_or_above() AND v_meeting.organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to finalize minutes for this meeting';
  END IF;
  IF v_meeting.minutes IS NULL OR btrim(v_meeting.minutes) = '' THEN
    RAISE EXCEPTION 'Cannot finalize empty minutes — add minutes first';
  END IF;
  IF v_meeting.minutes_finalized THEN
    RAISE EXCEPTION 'Minutes have already been finalized';
  END IF;

  UPDATE meetings SET minutes_finalized = TRUE WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'minutes_finalized', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. audit_logs CHECK extension ──────────────────────────────
-- Full accumulated list restated (per docs/23 §0's coordination
-- note), not a bare addition — every value already present in
-- patch-meetings-attendance.sql's own extension, plus exactly two new
-- values. No notifications.type change accompanies this patch — the
-- implementation specification lists meeting-minutes notifications as
-- optional/not-required-for-parity (docs/23 Phase B §7), so none is
-- added here.
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned',
    'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden',
    'unassigned', 'participant_added', 'participant_removed',
    'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked',
    'minutes_updated', 'minutes_finalized'
  ));

COMMIT;
