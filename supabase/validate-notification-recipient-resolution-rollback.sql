-- CAP-003 Phase 1.2 notification recipient resolution rollback
-- validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- Every 1.2-introduced object must be gone.
  IF to_regclass('public.notification_intents') IS NOT NULL THEN v_missing := v_missing || 'notification_intents-still-present '; END IF;
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'create_notification_intent-still-present '; END IF;
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-still-present '; END IF;
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_workflow_instance-still-present '; END IF;
  IF to_regprocedure('public.intent_user_is_super_admin(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_is_super_admin-still-present '; END IF;
  IF to_regprocedure('public.notification_intents_enforce_immutability()') IS NOT NULL THEN
    v_missing := v_missing || 'notification_intents-immutability-function-still-present '; END IF;

  -- CAP-003 Phase 1.1 (notification outbox persistence foundation) must
  -- be completely unaffected -- this rollback never touched it.
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-platform_outbox_events-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-user_notifications-missing '; END IF;
  IF to_regclass('public.platform_event_type_registry') IS NULL THEN v_missing := v_missing || 'phase1.1-platform_event_type_registry-missing '; END IF;
  IF to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-platform_enqueue_outbox_event-missing '; END IF;
  IF to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-platform_create_user_notification-missing '; END IF;
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-list_my_notifications-missing '; END IF;
  IF to_regprocedure('public.count_my_unread_notifications()') IS NULL THEN
    v_missing := v_missing || 'phase1.1-count_my_unread_notifications-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND cmd='SELECT' AND qual='(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'phase1.1-user_notifications_select-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications') <> 2 THEN
    v_missing := v_missing || 'phase1.1-user_notifications-policy-count-drift ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events'
  ) THEN v_missing := v_missing || 'phase1.1-outbox-unexpected-policy-present '; END IF;

  -- CAP-003 1.0A/1.0B (legacy notification fixes) must be completely
  -- unaffected -- this rollback never touched them either.
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
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_participants') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification recipient resolution rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification recipient resolution rollback validation PASSED (all Phase 1.2 tables/functions/triggers absent, CAP-003 Phase 1.1/1.0A/1.0B baselines and CAP-002 baseline all completely unaffected).';
END $$;
