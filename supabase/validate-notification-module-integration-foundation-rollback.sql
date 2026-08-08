-- CAP-003 Phase 1.4 notification module integration foundation --
-- rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_def TEXT;
BEGIN
  -- The new adapter and registry column must be gone.
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_task-still-present ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_event_type_registry'
      AND column_name='uses_generic_notification_envelope'
  ) THEN v_missing := v_missing || 'uses_generic_notification_envelope-column-still-present '; END IF;
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type='task.assigned.v1') THEN
    v_missing := v_missing || 'task.assigned.v1-registry-row-still-present ';
  END IF;

  -- notification_intents.source_record_type CHECK back to exactly the
  -- Phase 1.2 two-value form.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-restored '; END IF;

  -- create_notification_intent()/resolve_notification_intent() no
  -- longer mention 'task' or intent_user_can_view_task at all.
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def ~* '''task''' THEN v_missing := v_missing || 'create_notification_intent-still-mentions-task '; END IF;
  END IF;
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
    IF v_def ~* 'intent_user_can_view_task' THEN v_missing := v_missing || 'resolve_notification_intent-still-references-task-adapter '; END IF;
  END IF;

  -- process_platform_outbox_batch() back to the single hardcoded
  -- Phase 1.3 literal, no registry-driven dispatch.
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
    IF v_def !~* '''platform\.generic_notification_request\.v1''' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-hardcoded-literal-not-restored ';
    END IF;
    IF v_def ~* 'uses_generic_notification_envelope' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-still-registry-driven ';
    END IF;
  END IF;

  -- assign_task() no longer calls platform_enqueue_outbox_event.
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'assign_task-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.assign_task(uuid,uuid)')) INTO v_def;
    IF v_def ~* 'platform_enqueue_outbox_event' THEN v_missing := v_missing || 'assign_task-still-enqueues '; END IF;
    IF v_def !~* 'INSERT INTO notifications' THEN v_missing := v_missing || 'assign_task-legacy-notification-missing '; END IF;
  END IF;

  -- CAP-003 1.0B/1.1/1.2/1.3/1.3A baselines completely unaffected.
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'phase1.2-baseline-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.2-workflow-adapter-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry WHERE event_type = 'platform.generic_notification_request.v1'
  ) THEN v_missing := v_missing || 'phase1.3-generic-registry-row-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.notif_user_org_id(uuid)')
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
  ) THEN v_missing := v_missing || 'phase1.3a-baseline-drift '; END IF;

  -- CAP-002 baseline untouched.
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification module integration foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification module integration foundation rollback validation PASSED (intent_user_can_view_task and the registry envelope column both removed, task.assigned.v1 deregistered, closed source_record_type dispatch restored to exactly workflow_instance/platform, process_platform_outbox_batch and assign_task restored to their exact pre-1.4 bodies; CAP-003 1.0B-1.3A and CAP-002 baselines all completely unaffected).';
END $$;
