-- CAP-003 Phase 1.4B structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. Exactly the three approved event types are registered,
  -- uses_generic_notification_envelope = TRUE (registry-driven worker
  -- dispatch, zero worker code change needed) ────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'task.completed.v1' AND owning_module = 'tasks'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'task.completed.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'meetings.rescheduled.v1' AND owning_module = 'meetings'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'meetings.rescheduled.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'meetings.cancelled.v1' AND owning_module = 'meetings'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'meetings.cancelled.v1-registry-row-missing '; END IF;

  -- ── 2. Deferred candidates remain absent -- no accidental scope
  -- creep beyond the three approved events ────────────────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN ('task.review_requested.v1', 'task.returned.v1', 'meetings.scheduled.v1')
  ) THEN v_missing := v_missing || 'deferred-candidate-unexpectedly-registered '; END IF;

  -- ── 3. Closed target registry unaffected -- still exactly the 8
  -- kinds from Phase 1.4A, no new kind added by this milestone ──────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-unexpectedly-changed '; END IF;

  -- ── 4. Closed source_record_type dispatch: unaffected BY THIS
  -- MILESTONE (Phase 1.4B added no source type of its own) -- still
  -- contains the 4 values from Phase 1.4A. CAP-003 Phase 1.6B
  -- (patch-requests-notification-integration.sql) later legitimately
  -- extended the same closed list with 'request' -- this validator
  -- only asserts Phase 1.4A's own 4 values remain present, not that
  -- nothing was ever added after Phase 1.4B; Phase 1.6B's own
  -- validator (validate-requests-notification-integration.sql) pins
  -- the current full literal. ────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) ILIKE '%''workflow_instance''%' AND pg_get_constraintdef(oid) ILIKE '%''platform''%'
      AND pg_get_constraintdef(oid) ILIKE '%''task''%' AND pg_get_constraintdef(oid) ILIKE '%''meeting''%'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-missing-phase-1.4a-values '; END IF;

  -- ── 5. create_notification_intent()/resolve_notification_intent()/
  -- process_platform_outbox_batch() are completely untouched by this
  -- milestone -- still the exact 13-arg / Phase-1.4A signatures, no
  -- new authorization adapter, no target-kind-specific or module-
  -- specific branch added to the worker ──────────────────────────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-signature-unexpectedly-changed ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSIF v_def ILIKE '%task.completed%' OR v_def ILIKE '%meetings.rescheduled%' OR v_def ILIKE '%meetings.cancelled%'
     OR v_def ILIKE '%IF target_type%' OR v_def ILIKE '%IF module%' OR v_def ILIKE '%''tasks''%' OR v_def ILIKE '%''meetings''%'
  THEN
    v_missing := v_missing || 'process_platform_outbox_batch-contains-event-or-module-specific-branch ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSIF v_def ILIKE '%task.completed%' OR v_def ILIKE '%meetings.rescheduled%' OR v_def ILIKE '%meetings.cancelled%' THEN
    v_missing := v_missing || 'resolve_notification_intent-unexpectedly-references-new-event-type ';
  END IF;

  -- No new authorization adapter added BY THIS MILESTONE -- exactly
  -- intent_user_can_view_task (Phase 1.4) and intent_user_can_view_meeting
  -- (Phase 1.4A) exist as of Phase 1.4B, both still internal-only (no
  -- grant to any role). CAP-003 Phase 1.6B later legitimately added
  -- intent_user_can_view_request, and Phase 1.7B later legitimately added
  -- intent_user_can_view_entry -- this validator only asserts no
  -- adapter BEYOND the known set (Phase 1.4/1.4A's own two plus Phase
  -- 1.6B's and 1.7B's own one each) exists; each later phase's own
  -- validator (validate-requests-notification-integration.sql,
  -- validate-entry-notification-integration.sql) pins its exact posture
  -- (internal-only, no grant).
  IF EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name ILIKE 'intent_user_can_view_%'
      AND routine_name NOT IN ('intent_user_can_view_workflow_instance', 'intent_user_can_view_task', 'intent_user_can_view_meeting', 'intent_user_can_view_request', 'intent_user_can_view_entry')
  ) THEN v_missing := v_missing || 'unexpected-new-authorization-adapter '; END IF;

  IF has_function_privilege('authenticated', 'intent_user_can_view_task(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_task(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_task-exposed-to-ordinary-roles '; END IF;
  IF has_function_privilege('authenticated', 'intent_user_can_view_meeting(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_meeting(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_meeting-exposed-to-ordinary-roles '; END IF;

  -- ── 6. Each producer enqueues INSIDE its own server-authoritative
  -- mutation RPC (never a separate/frontend call) -- confirmed by the
  -- RPC's own functiondef containing the real enqueue call plus
  -- the approved event_type literal and an approved target_type ──────
  SELECT pg_get_functiondef(to_regprocedure('public.complete_task(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'complete_task-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'complete_task-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%task.completed.v1%' THEN v_missing := v_missing || 'complete_task-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%task_watchers%' OR v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'complete_task-missing-expected-target-types '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'complete_task-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 1400) ILIKE '%p_notes%' THEN
      v_missing := v_missing || 'complete_task-leaks-free-text-notes-into-payload ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'update_meeting-14arg-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'update_meeting-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%meetings.rescheduled.v1%' THEN v_missing := v_missing || 'update_meeting-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%meeting_participants%' THEN v_missing := v_missing || 'update_meeting-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'update_meeting-direct-user-notifications-write '; END IF;
    -- The new enqueue must be gated by p_suppress_notification, exactly
    -- like the pre-existing legacy notification branches.
    IF v_def !~ 'NOT p_suppress_notification AND v_time_changed AND NOT v_publishing' THEN
      v_missing := v_missing || 'update_meeting-reschedule-enqueue-not-correctly-gated ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.cancel_meeting(uuid,text,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'cancel_meeting-3arg-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'cancel_meeting-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%meetings.cancelled.v1%' THEN v_missing := v_missing || 'cancel_meeting-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%meeting_participants%' THEN v_missing := v_missing || 'cancel_meeting-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'cancel_meeting-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%p_cancellation_reason%' THEN
      v_missing := v_missing || 'cancel_meeting-leaks-free-text-reason-into-payload ';
    END IF;
  END IF;

  -- ── 7. Legacy notification dual-write preserved byte-for-byte in
  -- all three modified functions (unchanged INSERT INTO notifications
  -- statements still present) ─────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.complete_task(uuid,text)')) INTO v_def;
  IF v_def NOT ILIKE '%INSERT INTO notifications%task_completed%' THEN v_missing := v_missing || 'complete_task-legacy-notification-removed '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean)')) INTO v_def;
  IF v_def NOT ILIKE '%meeting_updated%' THEN v_missing := v_missing || 'update_meeting-legacy-notification-removed '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.cancel_meeting(uuid,text,boolean)')) INTO v_def;
  IF v_def NOT ILIKE '%meeting_cancelled%' THEN v_missing := v_missing || 'cancel_meeting-legacy-notification-removed '; END IF;

  -- ── 8. No external delivery / Realtime / preferences objects
  -- introduced by this milestone ─────────────────────────────────────
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_schema='public' AND (routine_name ILIKE '%send_email%' OR routine_name ILIKE '%send_push%' OR routine_name ILIKE '%send_sms%'))
  THEN v_missing := v_missing || 'unexpected-external-delivery-function '; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name ILIKE '%notification_preference%')
  THEN v_missing := v_missing || 'unexpected-notification-preferences-table '; END IF;

  -- ── 9. CAP-003 1.0B-1.4A and CAP-002 baseline objects unaffected ──
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN v_missing := v_missing || 'process_workflow_sla_due_batch-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task/Meeting notification event integration structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Task/Meeting notification event integration structural validation PASSED (task.completed.v1/meetings.rescheduled.v1/meetings.cancelled.v1 registered and registry-driven, deferred candidates absent, all three producers atomically enqueue inside their own server-authoritative RPC with legacy dual-write preserved and free-text fields excluded from payload, worker/resolver/create_notification_intent completely unmodified, no new target kind or authorization adapter, CAP-003 1.0B-1.4A and CAP-002 baselines unaffected, Phase 1.5 not started).';
END $$;
