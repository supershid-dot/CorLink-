-- 148: A participant added AFTER a meeting is created gets the same
-- Telegram invitation (rich message + RSVP buttons) an original
-- participant gets at create time — previously add_participant() only
-- wrote a legacy in-app notifications row, with zero reach into the
-- CAP-003/Telegram pipeline docs/126-146 built out.
--
-- UAT: "after creating a meeting, and when i add new participants from
-- this window, how are they going to get telegram and system
-- notification for the meeting" — confirmed with the user: auto-send
-- on add, same as an original participant.
--
-- Reuses the exact same event type (meetings.scheduled.v1) and
-- title_template_key create_meeting()/update_meeting() already use —
-- process-meeting-notifications renders it identically (rich body +
-- Accept/Decline buttons) regardless of which RPC enqueued it.
--
-- The one real difference: target_type is 'specific_users' with
-- target_user_ids := ARRAY[p_user_id], not 'meeting_participants' —
-- resolve_notification_intent() would otherwise fan the event out to
-- EVERY current participant, re-notifying everyone already invited
-- every time one more person is added. Scoping to just the new
-- participant's own id is what keeps this to "one invitation, to the
-- one person who's new."
--
-- True current latest predecessor: patch-meetings-foundation.sql —
-- add_participant() has never been touched since (confirmed by
-- re-checking canonical-migration-order.txt positions and re-reading
-- the live function body directly). Reproduced verbatim below, plus
-- the one new trailing block.

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

    PERFORM platform_enqueue_outbox_event(
      'meetings.scheduled.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.scheduled.v1',
        'title_template_key', 'meetings.scheduled',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', v_meeting.title, 'start_at', v_meeting.start_at, 'scheduled_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(p_user_id),
        'target_meeting_id', p_meeting_id
      ),
      v_participant_id
    );
  END IF;

  RETURN v_participant_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
