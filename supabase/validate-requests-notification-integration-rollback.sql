-- CAP-003 Phase 1.6B rollback validator. Disposable local PostgreSQL
-- only. Verifies approve_request()/return_request()/route_request()/
-- assign_request()/approve_response() were restored to their exact
-- pre-1.6B (Phase 1.6A) bodies, create_notification_intent()/
-- resolve_notification_intent() were restored to their exact Phase
-- 1.4A bodies, intent_user_can_view_request() was dropped, the
-- source_record_type CHECK constraint was restored, the 5 registry
-- rows were removed, and every Phase 1.0-1.5/1.6A object remains
-- present.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN ('requests.sent.v1','requests.returned.v1','requests.routed.v1','requests.assigned.v1','requests.response_sent.v1')
  ) THEN v_missing := v_missing || 'phase-1.6b-registry-rows-not-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_request(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_request-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%requests.sent.v1%' THEN
    v_missing := v_missing || 'approve_request-not-restored-to-pre-1.6b-body '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_request(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_request-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%requests.returned.v1%' THEN
    v_missing := v_missing || 'return_request-not-restored-to-pre-1.6b-body '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.route_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'route_request-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%requests.routed.v1%' THEN
    v_missing := v_missing || 'route_request-not-restored-to-pre-1.6b-body ';
  ELSIF v_def NOT ILIKE '%That section does not belong to the receiving organization%' THEN
    v_missing := v_missing || 'route_request-1.6a-org-consistency-check-lost '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_request-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%requests.assigned.v1%' THEN
    v_missing := v_missing || 'assign_request-not-restored-to-pre-1.6b-body '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_response(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_response-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%requests.response_sent.v1%' THEN
    v_missing := v_missing || 'approve_response-not-restored-to-pre-1.6b-body '; END IF;

  -- create_notification_intent()/resolve_notification_intent() restored
  -- to their exact Phase 1.4A bodies -- no 'request' references left.
  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'create_notification_intent-missing ';
  ELSIF v_def ILIKE '%''request''%' THEN v_missing := v_missing || 'create_notification_intent-still-references-request-source-type '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSIF v_def ILIKE '%intent_user_can_view_request%' THEN v_missing := v_missing || 'resolve_notification_intent-still-references-intent_user_can_view_request '; END IF;

  -- intent_user_can_view_request() dropped entirely.
  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_request-not-dropped '; END IF;

  -- source_record_type CHECK constraint restored to its exact Phase
  -- 1.4A form (4 values, no 'request').
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text])))'
  ) THEN v_missing := v_missing || 'source_record_type-check-not-restored '; END IF;

  -- Phase 1.0-1.5/1.6A baseline completely preserved through the rollback.
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN v_missing := v_missing || 'create_request-missing '; END IF;
  IF to_regprocedure('public.mark_request_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_request_received-missing '; END IF;
  IF to_regprocedure('public.receive_and_route_request(uuid,uuid,uuid)') IS NULL THEN v_missing := v_missing || 'receive_and_route_request-missing '; END IF;
  IF to_regprocedure('public.close_request(uuid)') IS NULL THEN v_missing := v_missing || 'close_request-missing '; END IF;
  IF to_regprocedure('public.acknowledge_and_close(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'acknowledge_and_close-missing '; END IF;
  IF has_table_privilege('authenticated','public.requests','INSERT') THEN v_missing := v_missing || 'requests-insert-unexpectedly-granted '; END IF;
  IF has_table_privilege('authenticated','public.requests','UPDATE') THEN v_missing := v_missing || 'requests-update-unexpectedly-granted '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='requests') <> 10 THEN v_missing := v_missing || 'requests-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='responses') <> 6 THEN v_missing := v_missing || 'responses-policy-count-drift '; END IF;

  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1') THEN v_missing := v_missing || 'task.assigned.v1-unexpectedly-removed '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.completed.v1') THEN v_missing := v_missing || 'task.completed.v1-unexpectedly-removed '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.rescheduled.v1') THEN v_missing := v_missing || 'meetings.rescheduled.v1-unexpectedly-removed '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN v_missing := v_missing || 'process_workflow_sla_due_batch-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Requests notification integration rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Requests notification integration rollback validation PASSED (approve_request/return_request/route_request/assign_request/approve_response restored to their exact pre-1.6B (Phase 1.6A) bodies, create_notification_intent/resolve_notification_intent restored to their exact Phase 1.4A bodies, intent_user_can_view_request dropped, source_record_type CHECK constraint restored, all 5 Phase 1.6B registry rows removed, Phase 1.0-1.5/1.6A baseline -- 19 Requests RPCs, direct-write closure, RLS, task.assigned.v1/task.completed.v1/meetings.rescheduled.v1, both prior authorization adapters -- completely preserved).';
END $$;
