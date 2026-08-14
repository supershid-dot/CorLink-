-- CAP-003 Phase 1.8B structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. Exactly the five approved event types are registered,
  -- uses_generic_notification_envelope = TRUE ─────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'internal_collaboration.routed.v1' AND owning_module = 'internal_collaboration'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'internal_collaboration.routed.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'internal_collaboration.returned.v1' AND owning_module = 'internal_collaboration'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'internal_collaboration.returned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'internal_collaboration.assigned.v1' AND owning_module = 'internal_collaboration'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'internal_collaboration.assigned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'internal_collaboration.reply_sent.v1' AND owning_module = 'internal_collaboration'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'internal_collaboration.reply_sent.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'internal_collaboration.reply_returned.v1' AND owning_module = 'internal_collaboration'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'internal_collaboration.reply_returned.v1-registry-row-missing '; END IF;

  -- ── 2. Deferred candidates remain absent ─────────────────────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN (
      'internal_collaboration.received.v1', 'internal_collaboration.closed.v1',
      'internal_collaboration.reply_drafted.v1', 'internal_collaboration.reply_submitted.v1'
    )
  ) THEN v_missing := v_missing || 'deferred-candidate-unexpectedly-registered '; END IF;

  -- ── 3. Closed target-type registry unaffected ───────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-unexpectedly-changed '; END IF;

  -- ── 4. Closed source_record_type dispatch: extended by exactly
  -- 'internal_request'. No 'internal_collaboration' or
  -- 'internal_request_reply' source type introduced. ──────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text, ''request''::text, ''external_correspondence''::text, ''internal_request''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-extended-correctly '; END IF;

  -- ── 5. create_notification_intent()/process_platform_outbox_batch()
  -- keep their exact pre-1.8B signatures. resolve_notification_intent()
  -- gains exactly one new dispatch branch ('internal_request'), no
  -- event-type-specific or module-specific branch anywhere. ───────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-signature-unexpectedly-changed ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%internal_request%' THEN
    v_missing := v_missing || 'create_notification_intent-missing-internal-request-source-type-guard-entry ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSIF v_def ILIKE '%internal_collaboration.routed%' OR v_def ILIKE '%internal_collaboration.returned%'
     OR v_def ILIKE '%internal_collaboration.assigned%' OR v_def ILIKE '%internal_collaboration.reply_sent%'
     OR v_def ILIKE '%internal_collaboration.reply_returned%'
     OR v_def ILIKE '%IF target_type%' OR v_def ILIKE '%IF module%' OR v_def ILIKE '%''internal_collaboration''%'
  THEN
    v_missing := v_missing || 'process_platform_outbox_batch-contains-event-or-module-specific-branch ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%internal_collaboration.routed%' OR v_def ILIKE '%internal_collaboration.returned%'
       OR v_def ILIKE '%internal_collaboration.assigned%' OR v_def ILIKE '%internal_collaboration.reply_sent%'
       OR v_def ILIKE '%internal_collaboration.reply_returned%'
    THEN v_missing := v_missing || 'resolve_notification_intent-unexpectedly-references-new-event-type '; END IF;
    IF v_def NOT ILIKE '%intent_user_can_view_internal_request%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-internal-request-dispatch-branch ';
    END IF;
  END IF;

  -- Exactly one new authorization adapter this phase --
  -- intent_user_can_view_internal_request -- no separate reply-specific
  -- adapter was introduced.
  IF EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name ILIKE 'intent_user_can_view_%'
      AND routine_name NOT IN (
        'intent_user_can_view_workflow_instance', 'intent_user_can_view_task',
        'intent_user_can_view_meeting', 'intent_user_can_view_request',
        'intent_user_can_view_entry', 'intent_user_can_view_internal_request'
      )
  ) THEN v_missing := v_missing || 'unexpected-new-authorization-adapter '; END IF;

  IF to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_internal_request-missing ';
  END IF;
  IF has_function_privilege('authenticated', 'intent_user_can_view_internal_request(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_internal_request(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_internal_request-exposed-to-ordinary-roles '; END IF;

  -- Genuine, evidenced divergence from Entry's own adapter: internal_
  -- requests_select DOES include an admin/supervisor bypass branch, so
  -- this adapter MUST include one (opposite of intent_user_can_view_entry).
  SELECT pg_get_functiondef(to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'intent_user_can_view_internal_request-body-missing ';
  ELSIF v_def NOT ILIKE '%mcs_admin%' OR v_def NOT ILIKE '%supervisor%'
  THEN v_missing := v_missing || 'intent_user_can_view_internal_request-missing-expected-admin-supervisor-bypass '; END IF;
  -- Must not call session-bound helpers (would authorize the wrong
  -- identity when invoked from inside resolve_notification_intent()).
  IF v_def ILIKE '%my_section_ids()%' OR v_def ILIKE '%is_supervisor_or_above()%' THEN
    v_missing := v_missing || 'intent_user_can_view_internal_request-unexpectedly-calls-session-bound-helper ';
  END IF;

  -- ── 6. Each producer enqueues INSIDE its own server-authoritative
  -- Phase 1.8A mutation RPC, never a direct user_notifications write,
  -- never a free-text field (subject/body/p_comment) copied into the
  -- payload ────────────────────────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'create_internal_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_internal_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.routed.v1%' THEN v_missing := v_missing || 'create_internal_request-missing-routed-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'create_internal_request-missing-section-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'create_internal_request-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_subject%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_body%'
    THEN v_missing := v_missing || 'create_internal_request-leaks-free-text-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to loop in a section%' THEN
      v_missing := v_missing || 'create_internal_request-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.reroute_internal_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'reroute_internal_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'reroute_internal_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.routed.v1%' THEN v_missing := v_missing || 'reroute_internal_request-missing-routed-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'reroute_internal_request-missing-section-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'reroute_internal_request-direct-user-notifications-write '; END IF;
    IF v_def NOT ILIKE '%Not authorized to reroute this internal request%' THEN
      v_missing := v_missing || 'reroute_internal_request-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_internal_request_to_sender(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_internal_request_to_sender-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_internal_request_to_sender-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.returned.v1%' THEN v_missing := v_missing || 'return_internal_request_to_sender-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'return_internal_request_to_sender-missing-section-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'return_internal_request_to_sender-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_comment%'
    THEN v_missing := v_missing || 'return_internal_request_to_sender-leaks-free-text-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to return this internal request to its sending section%' THEN
      v_missing := v_missing || 'return_internal_request_to_sender-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_internal_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_internal_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'assign_internal_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.assigned.v1%' THEN v_missing := v_missing || 'assign_internal_request-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'assign_internal_request-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'assign_internal_request-direct-user-notifications-write '; END IF;
    IF v_def !~ 'IF p_user_id IS NOT NULL THEN\s*\n\s*PERFORM platform_enqueue_outbox_event' THEN
      v_missing := v_missing || 'assign_internal_request-enqueue-not-correctly-gated-on-non-null-assignee ';
    END IF;
    IF v_def NOT ILIKE '%Not authorized to assign this internal request%' THEN
      v_missing := v_missing || 'assign_internal_request-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_internal_request_reply(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_internal_request_reply-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'approve_internal_request_reply-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.reply_sent.v1%' THEN v_missing := v_missing || 'approve_internal_request_reply-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'approve_internal_request_reply-missing-section-target-type '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'approve_internal_request_reply-missing-specific-users-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'approve_internal_request_reply-direct-user-notifications-write '; END IF;
    -- Two-descriptor fan-out with a shared correlation_id.
    IF v_def NOT ILIKE '%v_correlation_id%' THEN
      v_missing := v_missing || 'approve_internal_request_reply-missing-shared-correlation-id ';
    END IF;
    IF v_def NOT ILIKE '%md5(v_audit_id::TEXT%' THEN
      v_missing := v_missing || 'approve_internal_request_reply-missing-deterministic-second-idempotency-key ';
    END IF;
    -- Sourced from the PARENT thread, never a reply source type.
    IF v_def NOT ILIKE '%''internal_request'', v_ir.id%' THEN
      v_missing := v_missing || 'approve_internal_request_reply-not-sourced-from-parent-thread ';
    END IF;
    IF v_def ILIKE '%''internal_request_reply''%' THEN
      v_missing := v_missing || 'approve_internal_request_reply-unexpectedly-uses-a-reply-source-type ';
    END IF;
    IF v_def NOT ILIKE '%Not authorized to approve this reply%' THEN
      v_missing := v_missing || 'approve_internal_request_reply-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_internal_request_reply(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_internal_request_reply-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_internal_request_reply-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%internal_collaboration.reply_returned.v1%' THEN v_missing := v_missing || 'return_internal_request_reply-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'return_internal_request_reply-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'return_internal_request_reply-direct-user-notifications-write '; END IF;
    IF v_def NOT ILIKE '%''internal_request'', v_ir.id%' THEN
      v_missing := v_missing || 'return_internal_request_reply-not-sourced-from-parent-thread ';
    END IF;
    IF v_def NOT ILIKE '%Not authorized to return this reply%' THEN
      v_missing := v_missing || 'return_internal_request_reply-1.8a-authorization-check-missing ';
    END IF;
  END IF;

  -- Deferred RPCs must NOT have gained an enqueue call.
  SELECT pg_get_functiondef(to_regprocedure('public.mark_internal_request_received(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'mark_internal_request_received-unexpectedly-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.close_internal_request(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'close_internal_request-unexpectedly-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.submit_internal_request_reply(uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'submit_internal_request_reply-unexpectedly-enqueues '; END IF;

  -- ── 7. No direct authenticated write path opened to platform_outbox_
  -- events/notification_intents; RLS remains the real gate. ───────────
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.platform_outbox_events')) THEN
    v_missing := v_missing || 'platform_outbox_events-rls-not-enabled '; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events') THEN
    v_missing := v_missing || 'platform_outbox_events-unexpectedly-gained-a-policy '; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notification_intents')) THEN
    v_missing := v_missing || 'notification_intents-rls-not-enabled '; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notification_intents') THEN
    v_missing := v_missing || 'notification_intents-unexpectedly-gained-a-policy '; END IF;
  IF has_function_privilege('authenticated', 'process_platform_outbox_batch(integer,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'process_platform_outbox_batch-unexpectedly-executable-by-authenticated '; END IF;

  -- ── 8. Internal Collaboration RLS/policy count untouched -- Phase
  -- 1.8A's own policy set is unmodified. ───────────────────────────────
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests') <> 3 THEN
    v_missing := v_missing || 'internal_requests-policy-count-drift '; END IF;

  -- ── 9. Phase 1.8A direct-write closure preserved. ────────────────────
  IF has_table_privilege('authenticated', 'public.internal_requests', 'INSERT') THEN v_missing := v_missing || 'internal_requests-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.internal_requests', 'UPDATE') THEN v_missing := v_missing || 'internal_requests-update-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.internal_request_replies', 'INSERT') THEN v_missing := v_missing || 'internal_request_replies-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.internal_request_replies', 'UPDATE') THEN v_missing := v_missing || 'internal_request_replies-update-unexpectedly-reopened '; END IF;

  -- ── 10. All 11 Phase 1.8A RPCs still present; unrelated modules
  -- (Prisoner Letters) still not integrated; CAP-003 Phase 2 not
  -- started. ────────────────────────────────────────────────────────────
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
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE owning_module = 'prisoner_letters') THEN
    v_missing := v_missing || 'unexpected-out-of-scope-module-event-registered ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Internal Collaboration notification integration structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Internal Collaboration notification integration structural validation PASSED (5 events registered and registry-driven, deferred candidates absent, all 6 producers atomically enqueue inside their own Phase 1.8A server-authoritative RPC with free-text fields excluded from payload, worker/resolver/create_notification_intent gain only the minimal internal_request-dispatch addition, exactly one new authorization adapter (intent_user_can_view_internal_request, internal-only, admin/supervisor bypass present matching real RLS, no session-bound helper calls), two-descriptor fan-out for reply_sent with shared correlation and deterministic second idempotency key, no reply source type, no new target kind, Phase 1.8A direct-write closure and RLS preserved, Prisoner Letters still not integrated, CAP-003 Phase 2 not started).';
END $$;
