-- Rollback for patch-meetings-participant-added-notification.sql (148).
-- Restores add_participant() to its pre-148 body (patch-meetings-
-- foundation.sql's) — the legacy in-app notification stays, the
-- meetings.scheduled.v1 outbox enqueue is removed.

CREATE OR REPLACE FUNCTION add_participant(
  p_meeting_id UUID, p_user_id UUID DEFAULT NULL, p_external_name TEXT DEFAULT NULL,
  p_external_email TEXT DEFAULT NULL, p_external_phone TEXT DEFAULT NULL,
  p_external_organization_name TEXT DEFAULT NULL, p_participant_role TEXT DEFAULT 'attendee',
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_participant_id UUID;
  v_is_organizer BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'add_participant requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot add a participant to a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may manage participants';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to manage participants for this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF (p_user_id IS NOT NULL) = (p_external_name IS NOT NULL) THEN
    RAISE EXCEPTION 'Provide exactly one of user_id or external_name';
  END IF;
  IF p_participant_role NOT IN ('organizer', 'attendee', 'observer') THEN
    RAISE EXCEPTION 'Invalid participant_role: %', p_participant_role;
  END IF;

  v_is_organizer := (p_participant_role = 'organizer');

  BEGIN
    INSERT INTO meeting_participants (
      meeting_id, user_id, external_name, external_email, external_phone,
      external_organization_name, participant_role, is_organizer, invited_by, notes
    ) VALUES (
      p_meeting_id, p_user_id, p_external_name, p_external_email, p_external_phone,
      p_external_organization_name, p_participant_role, v_is_organizer, v_actor, p_notes
    ) RETURNING id INTO v_participant_id;
  EXCEPTION WHEN unique_violation THEN
    IF v_is_organizer THEN
      RAISE EXCEPTION 'This meeting already has an organizer';
    ELSE
      RAISE EXCEPTION 'This participant has already been added to the meeting';
    END IF;
  END;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'participant_added', 'meeting', p_meeting_id);

  IF p_user_id IS NOT NULL AND p_user_id <> v_actor AND v_meeting.status <> 'draft' THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (p_user_id, 'participant_added', 'meeting', p_meeting_id,
      'You have been added to a meeting: ' || v_meeting.title);
  END IF;

  RETURN v_participant_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
