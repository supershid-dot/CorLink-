-- ─── Validator: participant-removed Telegram notification (149) ─────
-- Run manually against a project AFTER
-- patch-meetings-participant-removed-notification.sql has been applied.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.participant_removed.v1') THEN
    v_missing := v_missing || 'event-type-not-registered ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.remove_participant(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'remove_participant-missing ';
  ELSE
    IF v_def NOT ILIKE '%meetings.participant_removed.v1%' THEN
      v_missing := v_missing || 'remove_participant-missing-enqueue ';
    END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN
      v_missing := v_missing || 'remove_participant-missing-specific_users-targeting ';
    END IF;
    IF v_def NOT ILIKE '%target_user_ids%' THEN
      v_missing := v_missing || 'remove_participant-missing-target_user_ids ';
    END IF;
    IF v_def NOT ILIKE '%v_participant.user_id IS NOT NULL AND NOT v_self AND v_meeting.status <> ''draft''%' THEN
      v_missing := v_missing || 'remove_participant-missing-guard-conditions ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-meetings-participant-removed-notification FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-meetings-participant-removed-notification: all checks passed';
END $$;
