-- ─── Patch: Meeting RSVP Responses (docs/22 Phase A, docs/23 §Phase A) ──
-- Requires patch-meetings-foundation.sql already applied. Closes the
-- existing schema/UI mismatch: meeting_participants.invitation_status
-- already exists but nothing lets a participant update it. This patch
-- adds exactly that — RSVP response only. It deliberately does NOT
-- touch attendance_status/attendance_marked_by/attendance_marked_at
-- (a separate Phase A feature, out of scope for this patch) and does
-- NOT touch meeting minutes, personal notes, or meeting locking
-- (Phase B). Idempotent — safe to re-run.
BEGIN;

-- ─── 1. meeting_participants: invitation_note column ───────────
-- Mirrors the accept/decline "why" note a participant may leave —
-- shown at the same visibility level as invitation_status itself
-- (i.e. unredacted to anyone who can already see the participant row
-- via meeting_participant_list()), distinct from Phase B's future
-- personal_notes column, which will be private to the participant.
ALTER TABLE meeting_participants ADD COLUMN IF NOT EXISTS invitation_note TEXT;

-- ─── 2. meeting_participant_list(): include invitation_note ────
-- Adding an output column to a RETURNS TABLE function is a return-type
-- change — CREATE OR REPLACE alone is rejected by Postgres for this;
-- the function must be dropped and recreated, same principle already
-- established for reschedule_booking's parameter-signature change in
-- patch-meetings-foundation.sql. Every other line of this function is
-- unchanged from the shipped version.
DROP FUNCTION IF EXISTS meeting_participant_list(UUID);
CREATE OR REPLACE FUNCTION meeting_participant_list(p_meeting_id UUID)
RETURNS TABLE (
  id UUID, user_id UUID, external_name TEXT, external_email TEXT, external_phone TEXT,
  external_organization_name TEXT, participant_role TEXT, invitation_status TEXT,
  invitation_note TEXT, attendance_status TEXT, is_organizer BOOLEAN, notes TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_privileged BOOLEAN;
BEGIN
  IF NOT can_view_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to view this meeting''s participants';
  END IF;
  v_privileged := can_manage_meeting(p_meeting_id);

  RETURN QUERY
  SELECT mp.id, mp.user_id, mp.external_name,
    CASE WHEN v_privileged THEN mp.external_email ELSE NULL END,
    CASE WHEN v_privileged THEN mp.external_phone ELSE NULL END,
    mp.external_organization_name, mp.participant_role, mp.invitation_status,
    mp.invitation_note, mp.attendance_status, mp.is_organizer, mp.notes, mp.created_at
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.removed_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. respond_to_invitation() RPC ─────────────────────────────
-- SECURITY DEFINER, search_path pinned, actor from auth.uid() only —
-- same convention as every other Meetings RPC. A participant may only
-- respond on their own row (user_id = auth.uid()); an external
-- participant has no auth.uid() at all and can never satisfy this,
-- which is intentional (docs/12 §2 — no external participant portal).
-- No RLS policy change accompanies this patch: meeting_participants
-- keeps its existing SELECT-only, zero-write-policy shape — this RPC
-- is the only path that can ever change invitation_status/invitation_note,
-- exactly like every other mutation in this module.
CREATE OR REPLACE FUNCTION respond_to_invitation(
  p_participant_id UUID,
  p_response TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'respond_to_invitation requires an authenticated caller';
  END IF;
  IF p_response NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'Invalid response: % (expected accepted or declined)', p_response;
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;
  -- Own row only — no manager/admin override. Responding to an
  -- invitation is a personal act; can_manage_meeting() authority over
  -- the meeting does not extend to answering RSVPs on someone else's
  -- behalf. IS DISTINCT FROM also correctly rejects an external
  -- participant's NULL user_id against any possible actor.
  IF v_participant.user_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'Not authorized to respond on behalf of this participant';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot respond to a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  UPDATE meeting_participants SET
    invitation_status = p_response,
    invitation_note = p_note
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'invitation_responded', 'meeting', v_meeting.id, p_note);

  -- Notify the organizer (in the current V1 model this is always the
  -- creator — create_meeting auto-inserts them as the sole organizer,
  -- and no RPC exists to reassign that role). Skipped when the actor
  -- is themselves the organizer responding to their own row.
  IF v_meeting.created_by <> v_actor THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_meeting.created_by, 'participant_responded', 'meeting', v_meeting.id,
      'A participant has responded to your meeting invitation: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Notification / audit CHECK extensions ───────────────────
-- Full accumulated list restated (per docs/23 §0's coordination note),
-- not a bare addition — every value already present in
-- patch-meetings-foundation.sql's own extension, plus exactly one new
-- value each.
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention',
    'meeting_created', 'participant_added', 'meeting_updated',
    'room_assigned', 'meeting_cancelled', 'participant_removed',
    'participant_responded'
  ));

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
    'invitation_responded'
  ));

COMMIT;
