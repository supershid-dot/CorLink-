-- CAP-003 Phase 1.5 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- user_notifications is no longer a member of supabase_realtime (when
  -- that publication object exists at all -- a no-op environment, like
  -- this disposable local Postgres harness, trivially satisfies "not a
  -- member" without ever having been one).
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_notifications'
  ) THEN v_missing := v_missing || 'user_notifications-still-in-supabase_realtime-publication '; END IF;

  -- Everything this milestone touched nothing of is still exactly
  -- present: user_notifications itself, its RLS, its read APIs, and
  -- every legacy dual-write this milestone's own equivalence review
  -- concluded must never be removed.
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF to_regclass('public.notifications') IS NULL THEN v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'list_my_notifications-missing '; END IF;
  IF to_regprocedure('public.count_my_unread_notifications()') IS NULL THEN
    v_missing := v_missing || 'count_my_unread_notifications-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND qual = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'user_notifications_select-policy-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_update' AND qual = '(recipient_user_id = auth.uid())'
      AND with_check = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'user_notifications_update-policy-drift '; END IF;

  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regprocedure('public.complete_task(uuid,text)') IS NULL THEN v_missing := v_missing || 'complete_task-missing '; END IF;
  IF to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean)') IS NULL THEN v_missing := v_missing || 'update_meeting-missing '; END IF;
  IF to_regprocedure('public.cancel_meeting(uuid,text,boolean)') IS NULL THEN v_missing := v_missing || 'cancel_meeting-missing '; END IF;

  -- CAP-002/CAP-003 baselines completely unaffected.
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'phase1.2-baseline-drift '; END IF;
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN v_missing := v_missing || 'phase1.3-baseline-drift '; END IF;
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification Realtime/legacy cutover rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification Realtime/legacy cutover rollback validation PASSED (user_notifications removed from supabase_realtime publication or was never a member, all Phase 1.1-1.4B objects/RLS/legacy dual-writes fully intact, CAP-002/CAP-003 baselines unaffected). Frontend rollback (js/data/notifications-api.js, js/views/shell.js) is a separate file-level revert -- see docs/88.';
END $$;
