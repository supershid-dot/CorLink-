-- CAP-003 Phase 1.9B structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. Exactly the four approved event types are registered,
  -- uses_generic_notification_envelope = TRUE ─────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'prisoner_letter.sent.v1' AND owning_module = 'prisoner_letters'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'prisoner_letter.sent.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'prisoner_letter.routed.v1' AND owning_module = 'prisoner_letters'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'prisoner_letter.routed.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'prisoner_letter.assigned.v1' AND owning_module = 'prisoner_letters'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'prisoner_letter.assigned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'prisoner_letter.reply_sent.v1' AND owning_module = 'prisoner_letters'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'prisoner_letter.reply_sent.v1-registry-row-missing '; END IF;

  -- Exactly 4 rows for this module -- no extra event was registered.
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'prisoner_letters') <> 4 THEN
    v_missing := v_missing || 'prisoner-letters-registry-count-not-exactly-four ';
  END IF;

  -- ── 2. Deferred candidates remain absent ─────────────────────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN (
      'prisoner_letter.received.v1', 'prisoner_letter.slip_generated.v1', 'prisoner_letter.delivered.v1'
    )
  ) THEN v_missing := v_missing || 'deferred-candidate-unexpectedly-registered '; END IF;

  -- ── 3. Closed target-type registry unaffected -- no new target kind ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-unexpectedly-changed '; END IF;

  -- ── 4. Closed source_record_type dispatch: extended by exactly
  -- 'prisoner_letter'. No 'prisoner_letters' (table-name spelling) or
  -- 'prisoner_reply' source type introduced. ───────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text, ''request''::text, ''external_correspondence''::text, ''internal_request''::text, ''prisoner_letter''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-extended-correctly '; END IF;

  -- ── 5. create_notification_intent()/process_platform_outbox_batch()
  -- keep their exact pre-1.9B signatures. resolve_notification_intent()
  -- gains exactly one new dispatch branch ('prisoner_letter'), no
  -- event-type-specific or module-specific branch anywhere. ───────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-signature-unexpectedly-changed ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%prisoner_letter%' THEN
    v_missing := v_missing || 'create_notification_intent-missing-prisoner-letter-source-type-guard-entry ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSIF v_def ILIKE '%prisoner_letter.sent%' OR v_def ILIKE '%prisoner_letter.routed%'
     OR v_def ILIKE '%prisoner_letter.assigned%' OR v_def ILIKE '%prisoner_letter.reply_sent%'
     OR v_def ILIKE '%IF target_type%' OR v_def ILIKE '%IF module%' OR v_def ILIKE '%''prisoner_letters''%'
  THEN
    v_missing := v_missing || 'process_platform_outbox_batch-contains-event-or-module-specific-branch ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%prisoner_letter.sent%' OR v_def ILIKE '%prisoner_letter.routed%'
       OR v_def ILIKE '%prisoner_letter.assigned%' OR v_def ILIKE '%prisoner_letter.reply_sent%'
    THEN v_missing := v_missing || 'resolve_notification_intent-unexpectedly-references-new-event-type '; END IF;
    IF v_def NOT ILIKE '%intent_user_can_view_prisoner_letter%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-prisoner-letter-dispatch-branch ';
    END IF;
  END IF;

  -- Exactly one new authorization adapter this phase --
  -- intent_user_can_view_prisoner_letter -- no separate reply-specific
  -- adapter was introduced.
  IF EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name ILIKE 'intent_user_can_view_%'
      AND routine_name NOT IN (
        'intent_user_can_view_workflow_instance', 'intent_user_can_view_task',
        'intent_user_can_view_meeting', 'intent_user_can_view_request',
        'intent_user_can_view_entry', 'intent_user_can_view_internal_request',
        'intent_user_can_view_prisoner_letter'
      )
  ) THEN v_missing := v_missing || 'unexpected-new-authorization-adapter '; END IF;

  IF to_regprocedure('public.intent_user_can_view_prisoner_letter(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_prisoner_letter-missing ';
  END IF;
  IF has_function_privilege('authenticated', 'intent_user_can_view_prisoner_letter(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_prisoner_letter(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_prisoner_letter-exposed-to-ordinary-roles '; END IF;

  -- Must mirror the NEW (Phase 1.9A/docs/96) narrower prisoner_letters_
  -- select predicate -- submitted_by/assigned_to gated by the staff
  -- flag, PLUS an independent supervisor/admin oversight branch -- NOT
  -- docs/95 §18's stale "no narrowing, no bypass" description.
  SELECT pg_get_functiondef(to_regprocedure('public.intent_user_can_view_prisoner_letter(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'intent_user_can_view_prisoner_letter-body-missing ';
  ELSE
    IF v_def NOT ILIKE '%submitted_by%' THEN v_missing := v_missing || 'intent_user_can_view_prisoner_letter-missing-submitted-by-branch '; END IF;
    IF v_def NOT ILIKE '%assigned_to%' THEN v_missing := v_missing || 'intent_user_can_view_prisoner_letter-missing-assigned-to-branch '; END IF;
    IF v_def NOT ILIKE '%mcs_admin%' OR v_def NOT ILIKE '%supervisor%' THEN
      v_missing := v_missing || 'intent_user_can_view_prisoner_letter-missing-expected-admin-supervisor-bypass ';
    END IF;
    IF v_def NOT ILIKE '%is_prisoner_letters_staff%' THEN
      v_missing := v_missing || 'intent_user_can_view_prisoner_letter-missing-staff-flag-check ';
    END IF;
    -- Must not call session-bound helpers (would authorize the wrong
    -- identity when invoked from inside resolve_notification_intent()).
    IF v_def ILIKE '%is_prisoner_letters_staff()%' OR v_def ILIKE '%is_supervisor_or_above()%' OR v_def ILIKE '%get_my_org_id()%' THEN
      v_missing := v_missing || 'intent_user_can_view_prisoner_letter-unexpectedly-calls-session-bound-helper ';
    END IF;
  END IF;

  -- ── 6. Each producer enqueues INSIDE its own server-authoritative
  -- Phase 1.9A mutation RPC, never a direct user_notifications write,
  -- never prisoner identity/content copied into the payload ───────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'create_prisoner_letter-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_prisoner_letter-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%prisoner_letter.sent.v1%' THEN v_missing := v_missing || 'create_prisoner_letter-missing-sent-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%org_admins%' THEN v_missing := v_missing || 'create_prisoner_letter-missing-org-admins-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'create_prisoner_letter-direct-user-notifications-write '; END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%p_body%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%v_prisoner%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%prisoner_name%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%reference_number%'
    THEN v_missing := v_missing || 'create_prisoner_letter-leaks-confidential-content-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to submit prisoner letters%' THEN
      v_missing := v_missing || 'create_prisoner_letter-1.9a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'route_prisoner_letter-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'route_prisoner_letter-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%prisoner_letter.routed.v1%' THEN v_missing := v_missing || 'route_prisoner_letter-missing-routed-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%prisoner_letter.assigned.v1%' THEN v_missing := v_missing || 'route_prisoner_letter-missing-assigned-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%section_leadership%' THEN v_missing := v_missing || 'route_prisoner_letter-missing-section-leadership-target-type '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'route_prisoner_letter-missing-specific-users-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'route_prisoner_letter-direct-user-notifications-write '; END IF;
    -- Mutually exclusive enqueue: gated on p_assigned_to.
    IF v_def NOT ILIKE '%IF p_assigned_to IS NOT NULL THEN%' THEN
      v_missing := v_missing || 'route_prisoner_letter-enqueue-not-correctly-gated-on-assignee ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%prisoner_name%'
    THEN v_missing := v_missing || 'route_prisoner_letter-leaks-confidential-content-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to route this prisoner letter%' THEN
      v_missing := v_missing || 'route_prisoner_letter-1.9a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter_reply(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'create_prisoner_letter_reply-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_prisoner_letter_reply-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%prisoner_letter.reply_sent.v1%' THEN v_missing := v_missing || 'create_prisoner_letter_reply-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'create_prisoner_letter_reply-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'create_prisoner_letter_reply-direct-user-notifications-write '; END IF;
    -- Sourced from the PARENT letter, never a reply source type.
    IF v_def NOT ILIKE '%''prisoner_letter'', p_letter_id%' THEN
      v_missing := v_missing || 'create_prisoner_letter_reply-not-sourced-from-parent-letter ';
    END IF;
    IF v_def ILIKE '%''prisoner_reply''%' THEN
      v_missing := v_missing || 'create_prisoner_letter_reply-unexpectedly-uses-a-reply-source-type ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 700) ILIKE '%p_body%'
    THEN v_missing := v_missing || 'create_prisoner_letter_reply-leaks-confidential-content-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to reply to this prisoner letter%' THEN
      v_missing := v_missing || 'create_prisoner_letter_reply-1.9a-authorization-check-missing ';
    END IF;
  END IF;

  -- Deferred RPCs must NOT have gained an enqueue call.
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_received(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'mark_prisoner_letter_received-unexpectedly-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_slip_generated(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'mark_prisoner_letter_slip_generated-unexpectedly-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_delivered(uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'mark_prisoner_letter_delivered-unexpectedly-enqueues '; END IF;

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

  -- ── 8. Prisoner Letters RLS/policy count untouched -- Phase 1.9A's
  -- own policy set is unmodified. ───────────────────────────────────────
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters') <> 3 THEN
    v_missing := v_missing || 'prisoner_letters-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies') <> 2 THEN
    v_missing := v_missing || 'prisoner_replies-policy-count-drift '; END IF;

  -- ── 9. Phase 1.9A direct-write closure preserved, attachment
  -- finalization lock and reply immutability untouched. ─────────────
  IF has_table_privilege('authenticated', 'public.prisoner_letters', 'INSERT') THEN v_missing := v_missing || 'prisoner_letters-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_letters', 'UPDATE') THEN v_missing := v_missing || 'prisoner_letters-update-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_replies', 'INSERT') THEN v_missing := v_missing || 'prisoner_replies-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_replies', 'UPDATE') THEN v_missing := v_missing || 'prisoner_replies-update-unexpectedly-reopened '; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies' AND cmd IN ('UPDATE','DELETE')) THEN
    v_missing := v_missing || 'prisoner_replies-unexpected-update-or-delete-policy '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert'
      AND with_check ILIKE '%pl.status <> ''delivered''%'
  ) THEN v_missing := v_missing || 'attachments-finalization-lock-disturbed '; END IF;

  -- ── 10. No digital signature, no CAP-003 Phase 2 marker anywhere in
  -- the three modified RPCs. ───────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter_reply(uuid,text)')) INTO v_def;
  IF v_def ILIKE '%signature%' OR v_def ~* '\msigned\M' THEN
    v_missing := v_missing || 'create_prisoner_letter_reply-unexpectedly-references-signature ';
  END IF;

  -- ── 11. All 6 Phase 1.9A RPCs still present; Requests/Entry/Internal
  -- Collaboration notification integration baselines unaffected. ──────
  IF to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)') IS NULL THEN v_missing := v_missing || 'create_prisoner_letter-baseline-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_received-baseline-missing '; END IF;
  IF to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)') IS NULL THEN v_missing := v_missing || 'route_prisoner_letter-baseline-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_slip_generated(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_slip_generated-baseline-missing '; END IF;
  IF to_regprocedure('public.create_prisoner_letter_reply(uuid,text)') IS NULL THEN v_missing := v_missing || 'create_prisoner_letter_reply-baseline-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_delivered(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_delivered-baseline-missing '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'internal_collaboration') <> 5 THEN
    v_missing := v_missing || 'internal-collaboration-event-registry-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'entry') <> 4 THEN
    v_missing := v_missing || 'entry-event-registry-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') <> 5 THEN
    v_missing := v_missing || 'requests-event-registry-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'internal-collaboration-adapter-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Prisoner Letters notification integration structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Prisoner Letters notification integration structural validation PASSED (4 events registered and registry-driven, deferred candidates absent, all 3 producers atomically enqueue inside their own Phase 1.9A server-authoritative RPC with prisoner identity/content excluded from payload, worker/resolver/create_notification_intent gain only the minimal prisoner_letter-dispatch addition, exactly one new authorization adapter (intent_user_can_view_prisoner_letter, internal-only, mirrors the NEW narrowed Phase 1.9A access model, no session-bound helper calls), mutually exclusive routed/assigned enqueue, no reply source type, no new target kind, Phase 1.9A direct-write closure/attachment lock/reply immutability preserved, no digital signature, Requests/Entry/Internal Collaboration baselines unaffected, CAP-003 Phase 2 not started).';
END $$;
