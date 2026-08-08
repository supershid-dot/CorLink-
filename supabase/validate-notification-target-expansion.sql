-- CAP-003 Phase 1.4A notification target expansion structural
-- validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── Exactly the two new target kinds exist; every existing kind
  -- remains supported ──────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-not-extended-exactly-as-expected '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notification_intents' AND column_name='target_task_id'
  ) THEN v_missing := v_missing || 'target_task_id-column-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notification_intents' AND column_name='target_meeting_id'
  ) THEN v_missing := v_missing || 'target_meeting_id-column-missing '; END IF;

  -- ── Closed source_record_type dispatch extended by exactly
  -- 'meeting' (task_watchers reuses the existing 'task' entry) ──────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-extended-exactly-as-expected '; END IF;

  -- ── Target-shape structural validation exists for both new kinds ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_shape_check'
      AND pg_get_constraintdef(oid) ILIKE '%task_watchers%target_task_id%'
      AND pg_get_constraintdef(oid) ILIKE '%meeting_participants%target_meeting_id%'
  ) THEN v_missing := v_missing || 'target_shape_check-missing-new-branches '; END IF;

  -- ── create_notification_intent(): old 11-arg signature genuinely
  -- gone (no orphaned overload), new 13-arg signature present and
  -- requires both new fields for their respective target kinds ─────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'create_notification_intent-old-11-arg-overload-still-present ';
  END IF;
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-13-arg-signature-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def !~* 'task_watchers' OR v_def !~* 'meeting_participants' THEN
      v_missing := v_missing || 'create_notification_intent-missing-new-target-branches '; END IF;
    IF v_def !~* '''workflow_instance''.*''platform''.*''task''.*''meeting''' THEN
      v_missing := v_missing || 'create_notification_intent-source-dispatch-not-extended-as-expected '; END IF;
  END IF;

  -- ── resolve_notification_intent(): new candidate-resolution
  -- branches reuse task_watchers/meeting_participant_recipient_ids()
  -- directly (never a duplicated resolution query), new 'meeting'
  -- authorization branch present, fail-closed ELSE still present ────
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
    IF v_def !~* 'FROM task_watchers' THEN v_missing := v_missing || 'resolve_notification_intent-missing-task_watchers-resolution '; END IF;
    IF v_def !~* 'meeting_participant_recipient_ids' THEN v_missing := v_missing || 'resolve_notification_intent-missing-meeting_participants-resolution-or-not-reusing-existing-helper '; END IF;
    IF v_def !~* 'intent_user_can_view_meeting' THEN v_missing := v_missing || 'resolve_notification_intent-missing-meeting-authorization-branch '; END IF;
    IF v_def !~* 'intent_user_can_view_task' THEN v_missing := v_missing || 'resolve_notification_intent-lost-existing-task-authorization-branch '; END IF;
    IF v_def !~* 'v_authorized\s*:=\s*FALSE' THEN v_missing := v_missing || 'resolve_notification_intent-missing-fail-closed-else-branch '; END IF;
  END IF;

  -- ── intent_user_can_view_meeting(): candidate-generalized adapter,
  -- service/internal-only, mirrors can_view_meeting ─────────────────
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_meeting-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'intent_user_can_view_meeting-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'intent_user_can_view_meeting-exposed-to-ordinary-roles '; END IF;
  END IF;

  -- ── Worker remains generic: no target-kind-specific or module-
  -- specific branch was added to process_platform_outbox_batch ─────
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
    IF v_def ~* '''task_watchers''' OR v_def ~* '''meeting_participants''' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-leaked-target-specific-branch '; END IF;
    IF v_def ~* '''tasks''' OR v_def ~* '''meetings''' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-leaked-module-specific-branch '; END IF;
    IF v_def !~* 'target_task_id' OR v_def !~* 'target_meeting_id' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-not-passing-new-generic-fields '; END IF;
    IF v_def !~* 'FOR UPDATE SKIP LOCKED' THEN v_missing := v_missing || 'process_platform_outbox_batch-missing-skip-locked '; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.process_platform_outbox_batch(integer,text)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'process_platform_outbox_batch-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'process_platform_outbox_batch-exposed-to-ordinary-roles '; END IF;
  END IF;

  -- ── No new domain event producer / registry row was added.
  -- task.assigned.v1 remains the only Phase 1.4 pilot event; no
  -- task.completed/meetings.* event type was registered ────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN ('task.completed.v1','task.review_requested.v1','task.returned.v1',
      'meetings.scheduled.v1','meetings.rescheduled.v1','meetings.cancelled.v1')
  ) THEN v_missing := v_missing || 'unexpected-new-domain-event-registered '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1'
  ) THEN v_missing := v_missing || 'phase1.4-pilot-event-missing '; END IF;

  -- ── No Task/Meeting lifecycle semantics changed: complete_task,
  -- assign_task, watch_task, unwatch_task, create_meeting,
  -- cancel_meeting bodies untouched by this milestone (only
  -- assign_task's own Phase 1.4 body, not touched again here) ──────
  IF to_regprocedure('public.watch_task(uuid)') IS NULL OR to_regprocedure('public.unwatch_task(uuid)') IS NULL THEN
    v_missing := v_missing || 'task-watcher-lifecycle-rpcs-missing '; END IF;
  IF to_regprocedure('public.can_view_meeting(uuid)') IS NULL THEN
    v_missing := v_missing || 'meeting-baseline-drift ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace
      AND proname IN ('watch_task','unwatch_task','complete_task','create_meeting','cancel_meeting')
      AND (pg_get_functiondef(oid) ILIKE '%platform_enqueue_outbox_event%' OR pg_get_functiondef(oid) ILIKE '%create_notification_intent%')
  ) THEN v_missing := v_missing || 'unexpected-task-meeting-lifecycle-mutation-now-enqueues-a-new-event-producer '; END IF;

  -- ── No direct user_notifications creation was introduced beyond
  -- the existing platform_create_user_notification() boundary; no
  -- direct authenticated intent creation ────────────────────────────
  IF has_function_privilege('authenticated', to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)'), 'EXECUTE')
     OR has_function_privilege('anon', to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)'), 'EXECUTE')
  THEN v_missing := v_missing || 'create_notification_intent-exposed-to-ordinary-roles '; END IF;

  -- ── CAP-003 1.0B-1.4 and CAP-002 baselines completely unaffected ──
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.2-workflow-adapter-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.4-task-adapter-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='platform_event_type_registry' AND column_name='uses_generic_notification_envelope'
  ) THEN v_missing := v_missing || 'phase1.4-registry-column-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.notif_user_org_id(uuid)')
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
  ) THEN v_missing := v_missing || 'phase1.3a-baseline-drift '; END IF;
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  -- ── Phase 1.5 not started (no delivery/Realtime objects) ─────────
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%send_email%','%send_push%','%send_sms%','%deliver_notification%','%realtime_cutover%'])
  ) THEN v_missing := v_missing || 'unexpected-phase1.5-delivery-object-exists '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification target expansion structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification target expansion structural validation PASSED (task_watchers and meeting_participants target kinds present with correct shape validation, source_record_type dispatch extended by exactly meeting (task_watchers reuses task), intent_user_can_view_meeting() present and locked down, worker remains generic with zero target/module-specific branches, no new domain event registered, task.assigned.v1 remains the sole pilot, Task/Meeting lifecycle RPCs untouched, CAP-003 1.0B-1.4 and CAP-002 baselines all completely unaffected, Phase 1.5 not started).';
END $$;
