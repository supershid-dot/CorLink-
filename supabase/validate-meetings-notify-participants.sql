-- ─── Validator: Notify Participants (144) ───────────────────────────
-- Run manually against a project AFTER
-- patch-meetings-notify-participants.sql has been applied there.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF to_regprocedure('public.get_meeting_telegram_recipients(uuid)') IS NULL THEN
    v_missing := v_missing || 'get_meeting_telegram_recipients-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.get_meeting_telegram_recipients(uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%can_manage_meeting%' THEN
      v_missing := v_missing || 'get_meeting_telegram_recipients-missing-authorization-check ';
    END IF;
    IF v_def NOT ILIKE '%telegram_chat_id IS NOT NULL%' THEN
      v_missing := v_missing || 'get_meeting_telegram_recipients-missing-has_telegram-projection ';
    END IF;
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM pg_constraint WHERE conname = 'audit_logs_action_check';
  IF v_def NOT ILIKE '%''meeting_notification_sent''%' THEN
    v_missing := v_missing || 'audit_logs_action_check-missing-meeting_notification_sent ';
  END IF;
  IF v_def NOT ILIKE '%''module_enabled''%' THEN
    v_missing := v_missing || 'audit_logs_action_check-lost-preexisting-value ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-meetings-notify-participants FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-meetings-notify-participants: all checks passed';
END $$;
