-- 149: A participant removed from a meeting now gets a Telegram
-- notification too, not just the existing in-app one.
--
-- UAT: "when removed from participant list, also should be notified"
-- (direct follow-up to docs/148's "added" side of the same gap).
--
-- remove_participant() already wrote a legacy in-app notifications row
-- ("You have been removed from a meeting: {title}") but never touched
-- the CAP-003/Telegram pipeline. New event type meetings.participant_
-- removed.v1 (registered here — the first genuinely new meetings.*
-- event type since docs/126-132; add/reminder/updated/rescheduled/
-- cancelled all already existed), enqueued the same way docs/148
-- enqueued meetings.scheduled.v1 from add_participant(): target_type
-- 'specific_users' with target_user_ids := ARRAY[the removed user's
-- id] only — never 'meeting_participants', which would notify
-- everyone still in the meeting about someone else's removal.
--
-- No RSVP buttons (send-meeting-telegram-notification/process-meeting-
-- notifications only ever attach them to 'meetings.scheduled' sends —
-- unaffected, no code change needed there for that). Message content
-- (Edge Function change, same migration-adjacent deploy) drops the
-- location/participant-roster lines a removed person no longer needs
-- to see, and includes the removal reason when one was given.

INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'meetings.participant_removed.v1', 'meetings', FALSE, FALSE,
    'A participant was removed from a meeting after it was created (remove_participant()). Recipients: specific_users target kind (the removed user only, never the rest of the meeting). Never fires for a self-removal, an external guest, or a still-unannounced draft meeting -- same guard remove_participant()''s existing legacy notification already used.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- True current latest predecessor: patch-meetings-foundation.sql —
-- remove_participant() has never been touched since (confirmed by
-- re-reading the live function body directly). Reproduced verbatim
-- below, plus the one new trailing block.
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

    PERFORM platform_enqueue_outbox_event(
      'meetings.participant_removed.v1', 'meetings', 'meeting', v_participant.meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.participant_removed.v1',
        'title_template_key', 'meetings.participant_removed',
        'template_params', jsonb_build_object(
          'meeting_id', v_participant.meeting_id, 'meeting_title', v_meeting.title,
          'start_at', v_meeting.start_at, 'reason', p_reason
        ),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(v_participant.user_id),
        'target_meeting_id', v_participant.meeting_id
      ),
      p_participant_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
