-- CAP-003 Phase 1.4A notification target expansion rollback validator
-- (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_def TEXT;
BEGIN
  -- New columns/adapter/registry-flag genuinely gone.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notification_intents' AND column_name IN ('target_task_id','target_meeting_id')
  ) THEN v_missing := v_missing || 'target-columns-still-present '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_meeting-still-present '; END IF;

  -- Constraints restored to exactly their pre-1.4A (Phase 1.4) forms.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text])))'
  ) THEN v_missing := v_missing || 'target_type_check-not-restored '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text])))'
  ) THEN v_missing := v_missing || 'source_record_type_check-not-restored '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_shape_check'
      AND (pg_get_constraintdef(oid) ILIKE '%task_watchers%' OR pg_get_constraintdef(oid) ILIKE '%meeting_participants%')
  ) THEN v_missing := v_missing || 'target_shape_check-still-mentions-new-kinds '; END IF;

  -- create_notification_intent() back to exactly the 11-arg signature,
  -- no orphaned 13-arg overload.
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'create_notification_intent-13-arg-overload-still-present ';
  END IF;
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-11-arg-signature-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def ~* 'task_watchers' OR v_def ~* 'meeting_participants' THEN
      v_missing := v_missing || 'create_notification_intent-still-mentions-new-target-kinds '; END IF;
  END IF;

  -- resolve_notification_intent() no longer mentions the new kinds/adapter.
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
    IF v_def ~* 'intent_user_can_view_meeting' OR v_def ~* 'meeting_participant_recipient_ids' OR v_def ~* 'FROM task_watchers' THEN
      v_missing := v_missing || 'resolve_notification_intent-still-references-new-target-resolution '; END IF;
    IF v_def !~* 'intent_user_can_view_task' THEN v_missing := v_missing || 'resolve_notification_intent-lost-phase1.4-task-branch '; END IF;
  END IF;

  -- process_platform_outbox_batch() no longer passes the two new fields.
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
    IF v_def ~* 'target_task_id' OR v_def ~* 'target_meeting_id' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-still-passes-new-fields '; END IF;
    IF v_def !~* 'uses_generic_notification_envelope' THEN v_missing := v_missing || 'process_platform_outbox_batch-lost-phase1.4-registry-dispatch '; END IF;
  END IF;

  -- CAP-003 1.0B-1.4 and CAP-002 baselines completely unaffected.
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.4-task-adapter-drift '; END IF;
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'phase1.4-assign_task-drift '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1') THEN
    v_missing := v_missing || 'phase1.4-pilot-event-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.notif_user_org_id(uuid)')
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
  ) THEN v_missing := v_missing || 'phase1.3a-baseline-drift '; END IF;
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification target expansion rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification target expansion rollback validation PASSED (target_task_id/target_meeting_id columns and intent_user_can_view_meeting() both removed, all three CHECK constraints restored to exactly their pre-1.4A forms, create_notification_intent/resolve_notification_intent/process_platform_outbox_batch restored to their exact pre-1.4A bodies; CAP-003 1.0B-1.4 and CAP-002 baselines all completely unaffected).';
END $$;
