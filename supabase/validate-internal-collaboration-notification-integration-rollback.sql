-- CAP-003 Phase 1.8B rollback validator. Confirms rollback-internal-
-- collaboration-notification-integration.sql restored the exact
-- pre-1.8B state, and that Phase 1.0-1.7B/1.8A baselines are preserved.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. The 5 registry rows are gone. ─────────────────────────────
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type LIKE 'internal_collaboration.%') THEN
    v_missing := v_missing || 'internal_collaboration-registry-rows-still-present ';
  END IF;

  -- ── 2. The adapter is gone. ───────────────────────────────────────
  IF to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_internal_request-still-present ';
  END IF;

  -- ── 3. source_record_type CHECK restored to exact Phase 1.7B set. ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text, ''request''::text, ''external_correspondence''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-restored '; END IF;

  -- ── 4. create_notification_intent()/resolve_notification_intent()
  -- no longer reference internal_request anywhere. ────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%internal_request%' THEN v_missing := v_missing || 'create_notification_intent-still-references-internal-request '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def ILIKE '%intent_user_can_view_internal_request%' THEN v_missing := v_missing || 'resolve_notification_intent-still-references-internal-request-adapter '; END IF;

  -- ── 5. The 6 modified RPCs no longer enqueue anything. ──────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_internal_request-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.reroute_internal_request(uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'reroute_internal_request-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.return_internal_request_to_sender(uuid,text)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_internal_request_to_sender-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.assign_internal_request(uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'assign_internal_request-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.approve_internal_request_reply(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'approve_internal_request_reply-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.return_internal_request_reply(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_internal_request_reply-still-enqueues '; END IF;

  -- ── 6. Phase 1.8A mutation foundation fully intact: all 11 RPCs
  -- still present, direct-write closure preserved. ────────────────────
  IF to_regprocedure('public.create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)') IS NULL THEN v_missing := v_missing || 'create_internal_request-missing '; END IF;
  IF to_regprocedure('public.mark_internal_request_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_internal_request_received-missing '; END IF;
  IF to_regprocedure('public.reroute_internal_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'reroute_internal_request-missing '; END IF;
  IF to_regprocedure('public.return_internal_request_to_sender(uuid,text)') IS NULL THEN v_missing := v_missing || 'return_internal_request_to_sender-missing '; END IF;
  IF to_regprocedure('public.assign_internal_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_internal_request-missing '; END IF;
  IF to_regprocedure('public.close_internal_request(uuid)') IS NULL THEN v_missing := v_missing || 'close_internal_request-missing '; END IF;
  IF to_regprocedure('public.draft_internal_request_reply(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'draft_internal_request_reply-missing '; END IF;
  IF to_regprocedure('public.update_internal_request_reply_draft(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'update_internal_request_reply_draft-missing '; END IF;
  IF to_regprocedure('public.submit_internal_request_reply(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'submit_internal_request_reply-missing '; END IF;
  IF to_regprocedure('public.approve_internal_request_reply(uuid)') IS NULL THEN v_missing := v_missing || 'approve_internal_request_reply-missing '; END IF;
  IF to_regprocedure('public.return_internal_request_reply(uuid)') IS NULL THEN v_missing := v_missing || 'return_internal_request_reply-missing '; END IF;
  IF has_table_privilege('authenticated', 'public.internal_requests', 'INSERT') THEN v_missing := v_missing || 'internal_requests-insert-unexpectedly-open '; END IF;
  IF has_table_privilege('authenticated', 'public.internal_request_replies', 'INSERT') THEN v_missing := v_missing || 'internal_request_replies-insert-unexpectedly-open '; END IF;

  -- ── 7. Prior CAP-003 baselines preserved: Entry/Requests adapters and
  -- their own registry rows still present and unaffected. ─────────────
  IF to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_entry-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_request-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'entry.routed.v1') THEN v_missing := v_missing || 'entry.routed.v1-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'requests.sent.v1') THEN v_missing := v_missing || 'requests.sent.v1-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Internal Collaboration notification integration ROLLBACK validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Internal Collaboration notification integration ROLLBACK validation PASSED (5 registry rows removed, adapter dropped, source_record_type CHECK restored to exact Phase 1.7B set, create_notification_intent/resolve_notification_intent no longer reference internal_request, all 6 modified RPCs no longer enqueue, Phase 1.8A mutation foundation and direct-write closure fully intact, prior CAP-003 baselines -- Entry/Requests/Task/Meeting adapters and registry rows -- untouched).';
END $$;
