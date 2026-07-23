-- ─── Patch: Meeting Attendance Marking (docs/22 Phase A, docs/23 §Phase A) ──
-- Requires patch-meetings-foundation.sql and patch-meetings-rsvp.sql
-- already applied. Closes the remaining half of the existing schema/UI
-- mismatch: meeting_participants.attendance_status already exists but
-- nothing lets an authorized user update it. Kept strictly separate
-- from RSVP (invitation_status/invitation_note) — attendance is marked
-- by a meeting manager about a participant; RSVP is a participant
-- responding for themselves. Neither RPC touches the other's columns.
-- Deliberately does NOT touch meeting minutes, personal notes,
-- calendar, meeting groups, recurring meetings, draft meetings, or
-- leave management. Idempotent — safe to re-run.
BEGIN;

-- ─── 1. meeting_participants: attendance tracking columns ──────
-- attendance_marked_by/attendance_marked_at record who marked
-- attendance and when (server-derived, never client-supplied — set
-- only inside mark_attendance() below). attendance_note is a free-text
-- annotation, shown at the same visibility level as attendance_status
-- itself (i.e. unredacted to anyone who can already see the
-- participant row via meeting_participant_list()) — same treatment
-- already given to invitation_note.
ALTER TABLE meeting_participants ADD COLUMN IF NOT EXISTS attendance_marked_by UUID REFERENCES users(id);
ALTER TABLE meeting_participants ADD COLUMN IF NOT EXISTS attendance_marked_at TIMESTAMPTZ;
ALTER TABLE meeting_participants ADD COLUMN IF NOT EXISTS attendance_note TEXT;

ALTER TABLE meeting_participants DROP CONSTRAINT IF EXISTS meeting_participants_attendance_marked_pair_check;
ALTER TABLE meeting_participants ADD CONSTRAINT meeting_participants_attendance_marked_pair_check
  CHECK ((attendance_marked_by IS NULL) = (attendance_marked_at IS NULL));

-- ─── 2. meeting_participant_list(): include attendance fields ──
-- Another return-type change — DROP FUNCTION required before
-- CREATE OR REPLACE, same as the RSVP patch's own addition of
-- invitation_note. Every other line unchanged from the RSVP-patched
-- version.
DROP FUNCTION IF EXISTS meeting_participant_list(UUID);
CREATE OR REPLACE FUNCTION meeting_participant_list(p_meeting_id UUID)
RETURNS TABLE (
  id UUID, user_id UUID, external_name TEXT, external_email TEXT, external_phone TEXT,
  external_organization_name TEXT, participant_role TEXT, invitation_status TEXT,
  invitation_note TEXT, attendance_status TEXT, attendance_note TEXT,
  is_organizer BOOLEAN, notes TEXT, created_at TIMESTAMPTZ
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
    mp.invitation_note, mp.attendance_status, mp.attendance_note,
    mp.is_organizer, mp.notes, mp.created_at
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.removed_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. mark_attendance() RPC ───────────────────────────────────
-- SECURITY DEFINER, search_path pinned, actor from auth.uid() only —
-- same convention as every other Meetings RPC. Authorization is
-- can_manage_meeting(), NOT "own row" — attendance is marked by a
-- meeting manager about a participant, the deliberate inverse of
-- respond_to_invitation's own-row-only rule. 'unknown' is the
-- unset/default value (meeting_participants_attendance_check already
-- constrains the column to unknown/attended/absent/excused) and is
-- intentionally not an accepted input here — there is no supported
-- "un-mark" action in this feature; only the three real attendance
-- outcomes can be recorded. No RLS policy change accompanies this
-- patch: meeting_participants keeps its existing SELECT-only,
-- zero-write-policy shape — this RPC is the only path that can ever
-- change attendance_status/attendance_marked_by/attendance_marked_at/
-- attendance_note.
CREATE OR REPLACE FUNCTION mark_attendance(
  p_participant_id UUID,
  p_status TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_attendance requires an authenticated caller';
  END IF;
  IF p_status NOT IN ('attended', 'absent', 'excused') THEN
    RAISE EXCEPTION 'Invalid attendance status: % (expected attended, absent, or excused)', p_status;
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot mark attendance on a cancelled meeting';
  END IF;
  IF NOT can_manage_meeting(v_participant.meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to mark attendance for this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  UPDATE meeting_participants SET
    attendance_status = p_status,
    attendance_marked_by = v_actor,
    attendance_marked_at = now(),
    attendance_note = p_note
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'attendance_marked', 'meeting', v_meeting.id, p_note);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. audit_logs CHECK extension ──────────────────────────────
-- Full accumulated list restated (per docs/23 §0's coordination
-- note), not a bare addition — every value already present in
-- patch-meetings-rsvp.sql's own extension, plus exactly one new
-- value. No notifications.type change accompanies this patch — the
-- implementation specification does not call for an attendance-marked
-- notification (docs/23 Phase A §7 lists only participant_responded),
-- so none is added here.
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
    'invitation_responded', 'attendance_marked'
  ));

COMMIT;
