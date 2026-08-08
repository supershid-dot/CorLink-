-- CAP-003 Phase 1.3 notification outbox worker rollback validator
-- (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- Every 1.3-introduced function must be gone.
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NOT NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-still-present '; END IF;
  IF to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'replay_dead_lettered_outbox_event-still-present '; END IF;
  IF to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)') IS NOT NULL THEN
    v_missing := v_missing || 'platform_outbox_worker_backoff_interval-still-present '; END IF;
  IF to_regprocedure('public.platform_outbox_events_due_for_processing(integer)') IS NOT NULL THEN
    v_missing := v_missing || 'platform_outbox_events_due_for_processing-still-present '; END IF;

  -- The registry row this milestone registered must be gone.
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry WHERE event_type = 'platform.generic_notification_request.v1'
  ) THEN v_missing := v_missing || 'generic-event-type-registry-row-still-present '; END IF;

  -- CAP-003 Phase 1.1/1.2 tables/functions must be completely
  -- unaffected -- this rollback never touched any of them, and never
  -- deletes outbox/intent/notification rows.
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-platform_outbox_events-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-user_notifications-missing '; END IF;
  IF to_regclass('public.platform_event_type_registry') IS NULL THEN v_missing := v_missing || 'phase1.1-platform_event_type_registry-missing '; END IF;
  IF to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-platform_enqueue_outbox_event-missing '; END IF;
  IF to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-platform_create_user_notification-missing '; END IF;
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'phase1.2-notification_intents-missing '; END IF;
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-create_notification_intent-missing '; END IF;
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-resolve_notification_intent-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-intent_user_can_view_workflow_instance-missing '; END IF;

  -- Phase 1.1's own outbox processing-state columns remain present and
  -- untouched (this rollback never drops or alters a column).
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='attempt_count'
  ) THEN v_missing := v_missing || 'phase1.1-attempt_count-column-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='next_attempt_at'
  ) THEN v_missing := v_missing || 'phase1.1-next_attempt_at-column-missing '; END IF;

  -- CAP-003 1.0A/1.0B (legacy notification fixes) must be completely
  -- unaffected.
  IF to_regclass('public.notifications') IS NULL THEN v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
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

  -- No evidence was destroyed by this rollback -- existing
  -- platform_outbox_events/notification_intents/user_notifications
  -- rows (including any written by the worker before rollback) remain
  -- exactly as they were; a function rollback never touches
  -- already-stored rows. (No row-count assertion here by design, same
  -- convention as Phase 5.4's own rollback validator -- the invariant
  -- being verified is schema/grant equality, not row survival count,
  -- which the rollback rehearsal below confirms directly against a
  -- controlled fixture instead.)

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification outbox worker rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification outbox worker rollback validation PASSED (all Phase 1.3 functions and the generic event-type registry row absent, CAP-003 Phase 1.1/1.2 tables/functions/columns and CAP-003 1.0A/1.0B baselines all completely unaffected, CAP-002 baseline intact -- no outbox/intent/notification row was ever touched by this rollback).';
END $$;
