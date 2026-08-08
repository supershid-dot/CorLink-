-- CAP-003 Phase 1.4 notification module integration foundation
-- structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── Generic event->intent mapping is registry-driven, not a
  -- worker code branch ─────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'platform_event_type_registry'
      AND column_name = 'uses_generic_notification_envelope' AND data_type = 'boolean'
  ) THEN v_missing := v_missing || 'platform_event_type_registry-missing-uses_generic_notification_envelope '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'platform.generic_notification_request.v1' AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'phase1.3-generic-envelope-flag-not-backfilled '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'task.assigned.v1' AND owning_module = 'tasks' AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'task.assigned.v1-not-registered '; END IF;

  -- ── process_platform_outbox_batch(): registry-driven dispatch, no
  -- hardcoded single event_type literal, no per-module branch ──────
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;

    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.process_platform_outbox_batch(integer,text)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'process_platform_outbox_batch-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'process_platform_outbox_batch-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'process_platform_outbox_batch-not-granted-to-service_role ';
    END IF;

    IF v_def ~* '''platform\.generic_notification_request\.v1''' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-still-hardcodes-event-type-literal ';
    END IF;
    IF v_def !~* 'uses_generic_notification_envelope' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-not-registry-driven ';
    END IF;
    -- Every other Phase 1.3 property must be byte-for-byte preserved.
    IF v_def !~* 'FOR UPDATE SKIP LOCKED' THEN v_missing := v_missing || 'process_platform_outbox_batch-missing-skip-locked '; END IF;
    IF v_def !~* 'LEAST\s*\(\s*GREATEST' THEN v_missing := v_missing || 'process_platform_outbox_batch-missing-hard-clamp '; END IF;
    IF v_def !~* 'create_notification_intent' THEN v_missing := v_missing || 'process_platform_outbox_batch-does-not-call-create_notification_intent '; END IF;
    IF v_def !~* 'resolve_notification_intent' THEN v_missing := v_missing || 'process_platform_outbox_batch-does-not-call-resolve_notification_intent '; END IF;
  END IF;

  -- ── intent_user_can_view_task(): candidate-generalized authorization
  -- adapter, service/internal-only, mirrors can_view_task ───────────
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_task-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.intent_user_can_view_task(uuid,uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'intent_user_can_view_task-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.intent_user_can_view_task(uuid,uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.intent_user_can_view_task(uuid,uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'intent_user_can_view_task-exposed-to-ordinary-roles '; END IF;
  END IF;

  -- ── Closed source_record_type dispatch: extended by exactly two
  -- literals ('task', 'meeting') as of Phase 1.4A, never opened to
  -- dynamic SQL or a wildcard ────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-extended-exactly-as-expected '; END IF;

  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def !~* '''workflow_instance''.*''platform''.*''task''' THEN
      v_missing := v_missing || 'create_notification_intent-dispatch-not-extended-as-expected ';
    END IF;
  END IF;

  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
    IF v_def !~* 'intent_user_can_view_task' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-task-authorization-branch ';
    END IF;
    -- No fallthrough default that authorizes an unrecognized type --
    -- the ELSE branch must still fail closed.
    IF v_def !~* 'v_authorized\s*:=\s*FALSE' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-fail-closed-else-branch ';
    END IF;
  END IF;

  -- ── assign_task(): atomic enqueue in the same transaction as the
  -- domain mutation, legacy dual-write preserved, idempotency key is
  -- the real assignment identity ────────────────────────────────────
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'assign_task-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.assign_task(uuid,uuid)')) INTO v_def;
    IF v_def !~* 'platform_enqueue_outbox_event' THEN
      v_missing := v_missing || 'assign_task-missing-atomic-outbox-enqueue ';
    END IF;
    IF v_def !~* 'INSERT INTO notifications' THEN
      v_missing := v_missing || 'assign_task-legacy-dual-write-removed-out-of-scope ';
    END IF;
    IF v_def !~* '''task\.assigned\.v1''' THEN
      v_missing := v_missing || 'assign_task-wrong-event-type ';
    END IF;
    IF v_def !~* 'v_assignment_id' OR v_def !~* 'platform_enqueue_outbox_event\s*\(.*v_assignment_id' THEN
      v_missing := v_missing || 'assign_task-idempotency-key-not-assignment-identity ';
    END IF;
  END IF;

  -- ── No module-specific branch was added to
  -- platform_enqueue_outbox_event / create_notification_intent /
  -- resolve_notification_intent's SHAPE beyond the one documented
  -- 'task' dispatch literal -- the worker itself carries zero new
  -- per-module code. ─────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.proname = 'process_platform_outbox_batch'
      AND pg_get_functiondef(p.oid) ~* '''task\.assigned'''
  ) THEN v_missing := v_missing || 'process_platform_outbox_batch-leaked-module-specific-branch '; END IF;

  -- ── CAP-003 1.0B/1.1/1.2/1.3/1.3A baselines completely unaffected ──
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'phase1.2-baseline-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.2-workflow-adapter-drift '; END IF;
  IF to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)') IS NULL THEN v_missing := v_missing || 'phase1.3-backoff-baseline-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.notif_user_org_id(uuid)')
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
  ) THEN v_missing := v_missing || 'phase1.3a-baseline-drift '; END IF;

  -- ── CAP-002 baseline untouched ──────────────────────────────────
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification module integration foundation structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification module integration foundation structural validation PASSED (registry-driven generic event->intent mapping, task.assigned.v1 pilot registered, intent_user_can_view_task() adapter present and locked down, closed source_record_type dispatch extended by exactly one literal, assign_task() atomically enqueues alongside its unmodified legacy dual-write, CAP-003 1.0B-1.3A and CAP-002 baselines all completely unaffected).';
END $$;
