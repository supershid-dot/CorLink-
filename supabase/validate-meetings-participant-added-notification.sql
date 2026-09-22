-- ─── Validator: participant-added Telegram invitation (148) ─────────
-- Run manually against a project AFTER
-- patch-meetings-participant-added-notification.sql has been applied.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.add_participant(uuid,uuid,text,text,text,text,text,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'add_participant-missing ';
  ELSE
    IF v_def NOT ILIKE '%meetings.scheduled.v1%' THEN
      v_missing := v_missing || 'add_participant-missing-enqueue ';
    END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN
      v_missing := v_missing || 'add_participant-missing-specific_users-targeting ';
    END IF;
    IF v_def NOT ILIKE '%target_user_ids%' THEN
      v_missing := v_missing || 'add_participant-missing-target_user_ids ';
    END IF;
    -- Must still guard on the same conditions the legacy notification
    -- already used — never fire for external guests, self-add, or a
    -- still-unannounced draft meeting.
    IF v_def NOT ILIKE '%p_user_id <> v_actor AND v_meeting.status <> ''draft''%' THEN
      v_missing := v_missing || 'add_participant-missing-guard-conditions ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-meetings-participant-added-notification FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-meetings-participant-added-notification: all checks passed';
END $$;
