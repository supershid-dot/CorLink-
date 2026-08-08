-- CAP-003 Phase 1.1 notification outbox persistence foundation
-- rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- Every 1.1-introduced object must be gone.
  IF to_regclass('public.platform_outbox_events') IS NOT NULL THEN v_missing := v_missing || 'platform_outbox_events-still-present '; END IF;
  IF to_regclass('public.user_notifications') IS NOT NULL THEN v_missing := v_missing || 'user_notifications-still-present '; END IF;
  IF to_regclass('public.platform_event_type_registry') IS NOT NULL THEN v_missing := v_missing || 'platform_event_type_registry-still-present '; END IF;
  IF to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'platform_enqueue_outbox_event-still-present '; END IF;
  IF to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)') IS NOT NULL THEN
    v_missing := v_missing || 'platform_create_user_notification-still-present '; END IF;
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NOT NULL THEN
    v_missing := v_missing || 'list_my_notifications-still-present '; END IF;
  IF to_regprocedure('public.count_my_unread_notifications()') IS NOT NULL THEN
    v_missing := v_missing || 'count_my_unread_notifications-still-present '; END IF;
  IF to_regprocedure('public.platform_outbox_events_enforce_immutability()') IS NOT NULL THEN
    v_missing := v_missing || 'outbox-immutability-function-still-present '; END IF;
  IF to_regprocedure('public.user_notifications_enforce_immutability()') IS NOT NULL THEN
    v_missing := v_missing || 'notification-immutability-function-still-present '; END IF;

  -- CAP-003 1.0A/1.0B (legacy notification fixes) must be completely
  -- unaffected -- this rollback never touched them.
  IF to_regclass('public.notifications') IS NULL THEN v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_update' AND cmd='UPDATE' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='notifications') <> 2 THEN
    v_missing := v_missing || 'notifications-policy-count-drift ';
  END IF;
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  END IF;
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_request_legitimate_recipient-missing (1.0B baseline drift) ';
  END IF;

  -- CAP-002 baseline untouched.
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_sla_clocks') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification outbox persistence foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification outbox persistence foundation rollback validation PASSED (all Phase 1.1 tables/functions/triggers absent, CAP-003 1.0A/1.0B legacy notification fixes and CAP-002 baseline both completely unaffected).';
END $$;
