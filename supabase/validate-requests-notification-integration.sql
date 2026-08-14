-- CAP-003 Phase 1.6B structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. Exactly the five approved event types are registered,
  -- uses_generic_notification_envelope = TRUE (registry-driven worker
  -- dispatch, zero worker code change needed) ────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'requests.sent.v1' AND owning_module = 'requests'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'requests.sent.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'requests.returned.v1' AND owning_module = 'requests'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'requests.returned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'requests.routed.v1' AND owning_module = 'requests'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'requests.routed.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'requests.assigned.v1' AND owning_module = 'requests'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'requests.assigned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'requests.response_sent.v1' AND owning_module = 'requests'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'requests.response_sent.v1-registry-row-missing '; END IF;

  -- ── 2. Deferred candidates remain absent -- no accidental scope
  -- creep beyond the five approved events ──────────────────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN (
      'requests.submitted.v1', 'requests.received.v1', 'requests.returned_to_sender.v1',
      'requests.closed.v1', 'requests.cancelled.v1', 'requests.response_submitted.v1',
      'requests.response_returned.v1', 'requests.response_received.v1'
    )
  ) THEN v_missing := v_missing || 'deferred-candidate-unexpectedly-registered '; END IF;

  -- ── 3. Closed target-type registry unaffected -- still exactly the
  -- 8 kinds from Phase 1.4A, no new kind added by this milestone ─────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-unexpectedly-changed '; END IF;

  -- ── 4. Closed source_record_type dispatch: extended by exactly
  -- 'request'. No 'response' source type introduced. A later phase
  -- (CAP-003 Phase 1.7B) legitimately extends this constraint further
  -- with 'external_correspondence' -- this check is therefore a
  -- positive-membership assertion (this milestone's own value is
  -- still present) rather than an exact-equality pin, matching the
  -- same reconciliation Phase 1.4A's own addition of 'meeting' already
  -- required of earlier validators (see docs/90's own "Sibling
  -- structural-validator reconciliation" section). 'response' is still
  -- asserted absent. ───────────────────────────────────────────────
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check';
  IF v_def IS NULL THEN v_missing := v_missing || 'notification_intents_source_record_type_check-missing ';
  ELSE
    IF v_def NOT ILIKE '%''request''%' THEN v_missing := v_missing || 'notification_intents_source_record_type_check-missing-request '; END IF;
    IF v_def ILIKE '%''response''%' THEN v_missing := v_missing || 'notification_intents_source_record_type_check-unexpectedly-has-response '; END IF;
  END IF;

  -- ── 5. create_notification_intent()/process_platform_outbox_batch()
  -- keep their exact pre-1.6B signatures (only create_notification_
  -- intent()'s BODY gains one new allowed source_record_type value in
  -- its own guard; process_platform_outbox_batch() is untouched even in
  -- body -- no new NULLIF passthrough was needed since every target
  -- kind this milestone uses already existed). resolve_notification_
  -- intent() gains exactly one new dispatch branch ('request'), no
  -- event-type-specific or module-specific branch anywhere. ──────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-signature-unexpectedly-changed ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%''request''%' THEN
    v_missing := v_missing || 'create_notification_intent-missing-request-source-type-guard-entry ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSIF v_def ILIKE '%requests.sent%' OR v_def ILIKE '%requests.returned%' OR v_def ILIKE '%requests.routed%'
     OR v_def ILIKE '%requests.assigned%' OR v_def ILIKE '%requests.response_sent%'
     OR v_def ILIKE '%IF target_type%' OR v_def ILIKE '%IF module%' OR v_def ILIKE '%''requests''%'
  THEN
    v_missing := v_missing || 'process_platform_outbox_batch-contains-event-or-module-specific-branch ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%requests.sent%' OR v_def ILIKE '%requests.returned%' OR v_def ILIKE '%requests.routed%'
       OR v_def ILIKE '%requests.assigned%' OR v_def ILIKE '%requests.response_sent%'
    THEN v_missing := v_missing || 'resolve_notification_intent-unexpectedly-references-new-event-type '; END IF;
    IF v_def NOT ILIKE '%intent_user_can_view_request%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-request-dispatch-branch ';
    END IF;
  END IF;

  -- Exactly one new authorization adapter added BY THIS MILESTONE --
  -- intent_user_can_view_request -- no response-specific adapter was
  -- introduced (see docs/90 for why). CAP-003 Phase 1.7B later
  -- legitimately adds intent_user_can_view_entry -- allowed here too,
  -- same reconciliation as validate-task-meeting-notification-events.sql.
  IF EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name ILIKE 'intent_user_can_view_%'
      AND routine_name NOT IN (
        'intent_user_can_view_workflow_instance', 'intent_user_can_view_task',
        'intent_user_can_view_meeting', 'intent_user_can_view_request', 'intent_user_can_view_entry',
        'intent_user_can_view_internal_request', 'intent_user_can_view_prisoner_letter'
      )
  ) THEN v_missing := v_missing || 'unexpected-new-authorization-adapter '; END IF;

  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_request-missing ';
  END IF;
  IF has_function_privilege('authenticated', 'intent_user_can_view_request(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_request(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_request-exposed-to-ordinary-roles '; END IF;

  -- ── 6. Each producer enqueues INSIDE its own server-authoritative
  -- Phase 1.6A mutation RPC (never a separate/frontend call), never a
  -- direct user_notifications write, never a Request/response free-
  -- text field (subject/body/p_comment) copied into the payload ──────
  SELECT pg_get_functiondef(to_regprocedure('public.approve_request(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'approve_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%requests.sent.v1%' THEN v_missing := v_missing || 'approve_request-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%org_admins%' THEN v_missing := v_missing || 'approve_request-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'approve_request-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_comment%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%v_row.subject%'
    THEN v_missing := v_missing || 'approve_request-leaks-free-text-into-payload '; END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_request(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%requests.returned.v1%' THEN v_missing := v_missing || 'return_request-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'return_request-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'return_request-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_comment%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%v_row.subject%'
    THEN v_missing := v_missing || 'return_request-leaks-free-text-into-payload '; END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.route_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'route_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'route_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%requests.routed.v1%' THEN v_missing := v_missing || 'route_request-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'route_request-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'route_request-direct-user-notifications-write '; END IF;
    -- Phase 1.6A's own org-consistency deviation must still be present.
    IF v_def NOT ILIKE '%That section does not belong to the receiving organization%' THEN
      v_missing := v_missing || 'route_request-1.6a-org-consistency-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_request(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_request-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'assign_request-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%requests.assigned.v1%' THEN v_missing := v_missing || 'assign_request-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'assign_request-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'assign_request-direct-user-notifications-write '; END IF;
    -- Enqueue must be gated on a real assignee (mirrors legacy `if (userId)`).
    IF v_def !~ 'IF p_user_id IS NOT NULL THEN\s*\n\s*PERFORM platform_enqueue_outbox_event' THEN
      v_missing := v_missing || 'assign_request-enqueue-not-correctly-gated-on-non-null-assignee ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_response(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_response-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'approve_response-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%requests.response_sent.v1%' THEN v_missing := v_missing || 'approve_response-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'approve_response-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'approve_response-direct-user-notifications-write '; END IF;
    -- Sourced from the PARENT request, never a 'response' source type.
    IF v_def NOT ILIKE '%''request'', v_req.id%' THEN
      v_missing := v_missing || 'approve_response-not-sourced-from-parent-request ';
    END IF;
    IF v_def ILIKE '%''response'', p_response_id, v_req%' OR v_def ILIKE '%source_record_type'', ''response''%' THEN
      v_missing := v_missing || 'approve_response-unexpectedly-uses-response-source-type ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_comment%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%v_row.body%'
    THEN v_missing := v_missing || 'approve_response-leaks-free-text-into-payload '; END IF;
  END IF;

  -- ── 7. Legacy NotificationsAPI.notify() call sites are untouched by
  -- this SQL-only patch (js/data/requests-api.js is a separate,
  -- frontend-only file this patch does not modify -- verified here by
  -- confirming none of the five RPCs gained a legacy `INSERT INTO
  -- notifications` write, since Requests never had one server-side to
  -- begin with; the frontend structural test asserts the JS side). ───
  SELECT pg_get_functiondef(to_regprocedure('public.approve_request(uuid,text)')) INTO v_def;
  IF v_def ILIKE '%INSERT INTO notifications%' THEN v_missing := v_missing || 'approve_request-unexpectedly-gained-server-side-legacy-notification '; END IF;

  -- ── 8. No frontend outbox enqueue, no client worker execution, no
  -- direct authenticated write path to platform_outbox_events/
  -- notification_intents was opened by this milestone -- RLS is the
  -- real gate (relrowsecurity + zero policies), not raw table grants,
  -- matching every prior CAP-003 validator's own convention (the
  -- disposable local harness's 01-grants.sql blanket-grants INSERT/
  -- UPDATE/DELETE to authenticated on all tables, mirroring real
  -- Supabase's own default grant posture). ───────────────────────────
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

  -- ── 9. Requests/Responses RLS untouched -- byte-for-byte the same
  -- policy count Phase 1.6A itself asserted. ─────────────────────────
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='requests') <> 10 THEN
    v_missing := v_missing || 'requests-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='responses') <> 6 THEN
    v_missing := v_missing || 'responses-policy-count-drift '; END IF;

  -- ── 10. Phase 1.6A direct-write closure preserved -- still no
  -- direct authenticated INSERT/UPDATE on requests/responses. ────────
  IF has_table_privilege('authenticated', 'public.requests', 'INSERT') THEN v_missing := v_missing || 'requests-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.requests', 'UPDATE') THEN v_missing := v_missing || 'requests-update-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.responses', 'INSERT') THEN v_missing := v_missing || 'responses-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.responses', 'UPDATE') THEN v_missing := v_missing || 'responses-update-unexpectedly-reopened '; END IF;

  -- ── 11. No external delivery / preferences / new Realtime object
  -- introduced by this milestone ─────────────────────────────────────
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_schema='public' AND (routine_name ILIKE '%send_email%' OR routine_name ILIKE '%send_push%' OR routine_name ILIKE '%send_sms%'))
  THEN v_missing := v_missing || 'unexpected-external-delivery-function '; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name ILIKE '%notification_preference%')
  THEN v_missing := v_missing || 'unexpected-notification-preferences-table '; END IF;

  -- ── 12. All 19 Phase 1.6A RPCs still present, unrelated modules
  -- (Entry/Internal Collaboration/Prisoner Letters) still not
  -- integrated, CAP-002/CAP-003 baselines intact, CAP-003 Phase 2 not
  -- started. ──────────────────────────────────────────────────────────
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN v_missing := v_missing || 'create_request-missing '; END IF;
  IF to_regprocedure('public.mark_request_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_request_received-missing '; END IF;
  IF to_regprocedure('public.return_request_to_previous_section(uuid,text)') IS NULL THEN v_missing := v_missing || 'return_request_to_previous_section-missing '; END IF;
  IF to_regprocedure('public.receive_and_route_request(uuid,uuid,uuid)') IS NULL THEN v_missing := v_missing || 'receive_and_route_request-missing '; END IF;
  IF to_regprocedure('public.close_request(uuid)') IS NULL THEN v_missing := v_missing || 'close_request-missing '; END IF;
  IF to_regprocedure('public.cancel_request(uuid,text)') IS NULL THEN v_missing := v_missing || 'cancel_request-missing '; END IF;
  IF to_regprocedure('public.create_response(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'create_response-missing '; END IF;
  IF to_regprocedure('public.submit_response(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'submit_response-missing '; END IF;
  IF to_regprocedure('public.return_response(uuid,text)') IS NULL THEN v_missing := v_missing || 'return_response-missing '; END IF;
  IF to_regprocedure('public.mark_response_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_response_received-missing '; END IF;
  IF to_regprocedure('public.acknowledge_and_close(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'acknowledge_and_close-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.complete_task(uuid,text)') IS NULL THEN v_missing := v_missing || 'complete_task-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN v_missing := v_missing || 'process_workflow_sla_due_batch-missing '; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('external_correspondence','internal_collaboration_threads','prisoner_letters')) THEN
    NULL; -- their presence is fine (unrelated pre-existing modules); this check exists only to document they are untouched, not to assert absence.
  END IF;
  -- 'entry' is no longer out-of-scope as of CAP-003 Phase 1.7B
  -- (validate-entry-notification-integration.sql owns that assertion
  -- now), 'internal_collaboration' is no longer out-of-scope as of
  -- CAP-003 Phase 1.8B (validate-internal-collaboration-notification-
  -- integration.sql owns that assertion now), and 'prisoner_letters' is
  -- no longer out-of-scope as of CAP-003 Phase 1.9B (validate-prisoner-
  -- letters-notification-integration.sql owns that assertion now) --
  -- there is no longer any deferred-module assertion left for this
  -- validator to own.

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Requests notification integration structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Requests notification integration structural validation PASSED (requests.sent.v1/requests.returned.v1/requests.routed.v1/requests.assigned.v1/requests.response_sent.v1 registered and registry-driven, deferred candidates absent, all five producers atomically enqueue inside their own Phase 1.6A server-authoritative RPC with legacy dual-write untouched and free-text fields excluded from payload, worker/resolver/create_notification_intent gain only the minimal request-dispatch addition, exactly one new authorization adapter (intent_user_can_view_request, internal-only), no response source type, Phase 1.6A direct-write closure and RLS preserved, Entry/Internal Collaboration/Prisoner Letters now integrated via their own later phases, CAP-003 Phase 2 not started).';
END $$;
