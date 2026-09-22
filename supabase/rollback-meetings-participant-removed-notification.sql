-- Rollback for patch-meetings-participant-removed-notification.sql (149).
-- Restores remove_participant() to its pre-149 body (patch-meetings-
-- foundation.sql's) — the legacy in-app notification stays, the
-- meetings.participant_removed.v1 outbox enqueue is removed. The event
-- type registry row is left in place (harmless once unused; deleting a
-- registry row a past outbox event may still reference is unnecessary
-- risk for a rollback).

CREATE OR REPLACE FUNCTION remove_participant(p_participant_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
  v_self BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'remove_participant requires an authenticated caller';
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Participant has already been removed';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(v_participant.meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may manage participants';
  END IF;

  v_self := (v_participant.user_id = v_actor);
  IF NOT (v_self OR can_manage_meeting(v_participant.meeting_id)) THEN
    RAISE EXCEPTION 'Not authorized to remove this participant';
  END IF;
  IF v_participant.is_organizer THEN
    RAISE EXCEPTION 'Cannot remove the meeting''s sole organizer';
  END IF;

  UPDATE meeting_participants SET
    removed_at = now(), removed_by = v_actor, removal_reason = p_reason
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'participant_removed', 'meeting', v_participant.meeting_id, p_reason);

  IF v_participant.user_id IS NOT NULL AND NOT v_self AND v_meeting.status <> 'draft' THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_participant.user_id, 'participant_removed', 'meeting', v_participant.meeting_id,
      'You have been removed from a meeting: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
