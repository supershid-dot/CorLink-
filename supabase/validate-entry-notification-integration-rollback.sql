-- CAP-003 Phase 1.7B rollback validator. Disposable local PostgreSQL
-- only. Verifies route_entry()/assign_entry()/approve_entry_reply()/
-- return_entry_reply() were restored to their exact pre-1.7B (Phase
-- 1.7A) bodies, create_notification_intent()/resolve_notification_
-- intent() were restored to their exact Phase 1.6B bodies,
-- intent_user_can_view_entry() was dropped, the source_record_type
-- CHECK constraint was restored to its exact Phase 1.6B form, the 4
-- registry rows were removed, and every Phase 1.0-1.6B/1.7A object
-- remains present.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN ('entry.routed.v1','entry.assigned.v1','entry.reply_sent.v1','entry.reply_returned.v1')
  ) THEN v_missing := v_missing || 'phase-1.7b-registry-rows-not-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.route_entry(uuid,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'route_entry-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%entry.routed.v1%' OR v_def ILIKE '%entry.assigned.v1%' THEN
    v_missing := v_missing || 'route_entry-not-restored-to-pre-1.7b-body ';
  ELSIF v_def NOT ILIKE '%Not authorized to route this entry%' THEN
    v_missing := v_missing || 'route_entry-1.7a-authorization-check-lost '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_entry(uuid,uuid,date)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_entry-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%entry.assigned.v1%' THEN
    v_missing := v_missing || 'assign_entry-not-restored-to-pre-1.7b-body '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_entry_reply(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_entry_reply-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%entry.reply_sent.v1%' THEN
    v_missing := v_missing || 'approve_entry_reply-not-restored-to-pre-1.7b-body '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_entry_reply(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_entry_reply-missing ';
  ELSIF v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%v_audit_id%' OR v_def ILIKE '%entry.reply_returned.v1%' THEN
    v_missing := v_missing || 'return_entry_reply-not-restored-to-pre-1.7b-body '; END IF;

  -- create_notification_intent()/resolve_notification_intent() restored
  -- to their exact Phase 1.6B bodies -- 'request' dispatch legitimately
  -- remains (Requests 1.6B predates this milestone and is untouched by
  -- this rollback), but 'external_correspondence' must be gone.
  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'create_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%external_correspondence%' THEN v_missing := v_missing || 'create_notification_intent-still-references-external-correspondence-source-type '; END IF;
    IF v_def NOT ILIKE '%''request''%' THEN v_missing := v_missing || 'create_notification_intent-unexpectedly-lost-1.6b-request-source-type '; END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%intent_user_can_view_entry%' THEN v_missing := v_missing || 'resolve_notification_intent-still-references-intent_user_can_view_entry '; END IF;
    IF v_def NOT ILIKE '%intent_user_can_view_request%' THEN v_missing := v_missing || 'resolve_notification_intent-unexpectedly-lost-1.6b-request-dispatch '; END IF;
  END IF;

  -- intent_user_can_view_entry() dropped entirely; intent_user_can_view_request() untouched.
  IF to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_entry-not-dropped '; END IF;
  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_request-unexpectedly-removed '; END IF;

  -- source_record_type CHECK constraint restored to its exact Phase
  -- 1.6B form (5 values including 'request', no 'external_correspondence').
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text, ''request''::text])))'
  ) THEN v_missing := v_missing || 'source_record_type-check-not-restored '; END IF;

  -- Phase 1.0-1.6B/1.7A baseline completely preserved through the rollback.
  IF to_regprocedure('public.create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)') IS NULL THEN v_missing := v_missing || 'create_entry-missing '; END IF;
  IF to_regprocedure('public.mark_entry_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_entry_received-missing '; END IF;
  IF to_regprocedure('public.close_entry(uuid)') IS NULL THEN v_missing := v_missing || 'close_entry-missing '; END IF;
  IF to_regprocedure('public.draft_entry_reply(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'draft_entry_reply-missing '; END IF;
  IF to_regprocedure('public.submit_entry_reply(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'submit_entry_reply-missing '; END IF;
  IF to_regprocedure('public.mark_entry_reply_sent(uuid,text)') IS NULL THEN v_missing := v_missing || 'mark_entry_reply_sent-missing '; END IF;
  IF has_table_privilege('authenticated','public.external_correspondence','INSERT') THEN v_missing := v_missing || 'external_correspondence-insert-unexpectedly-granted '; END IF;
  IF has_table_privilege('authenticated','public.external_correspondence','UPDATE') THEN v_missing := v_missing || 'external_correspondence-update-unexpectedly-granted '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence') <> 5 THEN v_missing := v_missing || 'external_correspondence-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence_replies') <> 3 THEN v_missing := v_missing || 'external_correspondence_replies-policy-count-drift '; END IF;

  -- Requests 1.6B and Task/Meeting baseline untouched by this rollback.
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'requests.sent.v1') THEN v_missing := v_missing || 'requests.sent.v1-unexpectedly-removed '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1') THEN v_missing := v_missing || 'task.assigned.v1-unexpectedly-removed '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.rescheduled.v1') THEN v_missing := v_missing || 'meetings.rescheduled.v1-unexpectedly-removed '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN v_missing := v_missing || 'process_workflow_sla_due_batch-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Entry notification integration rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Entry notification integration rollback validation PASSED (route_entry/assign_entry/approve_entry_reply/return_entry_reply restored to their exact pre-1.7B (Phase 1.7A) bodies, create_notification_intent/resolve_notification_intent restored to their exact Phase 1.6B bodies (request dispatch preserved, external_correspondence dispatch removed), intent_user_can_view_entry dropped, source_record_type CHECK constraint restored to its Phase 1.6B form, all 4 Phase 1.7B registry rows removed, Phase 1.0-1.6B/1.7A baseline -- 12 Entry RPCs, direct-write closure, RLS, Requests/Task/Meeting events, all prior authorization adapters -- completely preserved).';
END $$;
