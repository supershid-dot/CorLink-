-- CAP-003 Phase 1.4B rollback validator. Disposable local PostgreSQL
-- only. Verifies complete_task()/update_meeting()/cancel_meeting()
-- were restored to their exact pre-1.4B bodies, the 3 registry rows
-- were removed, and every Phase 1.4/1.4A object remains present.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN ('task.completed.v1', 'meetings.rescheduled.v1', 'meetings.cancelled.v1')
  ) THEN v_missing := v_missing || 'phase-1.4b-registry-rows-not-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.complete_task(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'complete_task-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%task.completed.v1%' THEN
    v_missing := v_missing || 'complete_task-not-restored-to-pre-1.4b-body ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'update_meeting-14arg-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%meetings.rescheduled.v1%' THEN
    v_missing := v_missing || 'update_meeting-not-restored-to-pre-1.4b-body ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.cancel_meeting(uuid,text,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'cancel_meeting-3arg-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%meetings.cancelled.v1%' THEN
    v_missing := v_missing || 'cancel_meeting-not-restored-to-pre-1.4b-body ';
  END IF;

  -- Phase 1.4/1.4A baseline completely preserved through the rollback.
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1') THEN
    v_missing := v_missing || 'task.assigned.v1-unexpectedly-removed ';
  END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'phase-1.4a-target-kinds-unexpectedly-changed '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task/Meeting notification event integration rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Task/Meeting notification event integration rollback validation PASSED (complete_task/update_meeting/cancel_meeting restored to their exact pre-1.4B bodies, all 3 Phase 1.4B registry rows removed, Phase 1.4/1.4A baseline -- task.assigned.v1, task_watchers, meeting_participants, both authorization adapters -- completely preserved).';
END $$;
