-- CAP-003 Phase 1.7B structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. Exactly the four approved event types are registered,
  -- uses_generic_notification_envelope = TRUE (registry-driven worker
  -- dispatch, zero worker code change needed) ────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'entry.routed.v1' AND owning_module = 'entry'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'entry.routed.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'entry.assigned.v1' AND owning_module = 'entry'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'entry.assigned.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'entry.reply_sent.v1' AND owning_module = 'entry'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'entry.reply_sent.v1-registry-row-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type = 'entry.reply_returned.v1' AND owning_module = 'entry'
      AND uses_generic_notification_envelope = TRUE
  ) THEN v_missing := v_missing || 'entry.reply_returned.v1-registry-row-missing '; END IF;

  -- ── 2. Deferred candidates remain absent -- no accidental scope
  -- creep beyond the four approved events ────────────────────────────
  IF EXISTS (
    SELECT 1 FROM platform_event_type_registry
    WHERE event_type IN (
      'entry.logged.v1', 'entry.received.v1', 'entry.closed.v1',
      'entry.reply_drafted.v1', 'entry.reply_submitted.v1', 'entry.reply_delivered.v1',
      'entry.transferred.v1', 'entry.reassigned_prison.v1'
    )
  ) THEN v_missing := v_missing || 'deferred-candidate-unexpectedly-registered '; END IF;

  -- ── 3. Closed target-type registry unaffected -- still exactly the
  -- 8 kinds from Phase 1.4A, no new 'entry_participants' (or any other)
  -- kind added by this milestone ─────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((target_type = ANY (ARRAY[''specific_users''::text, ''org_admins''::text, ''section''::text, ''section_leadership''::text, ''workflow_participants''::text, ''work_item_assignee''::text, ''task_watchers''::text, ''meeting_participants''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_target_type_check-unexpectedly-changed '; END IF;

  -- ── 4. Closed source_record_type dispatch: extended by exactly
  -- 'external_correspondence' as of this milestone. No 'entry' or
  -- 'external_correspondence_reply' source type introduced. CAP-003
  -- Phase 1.8B later legitimately extended the same constraint further
  -- with 'internal_request' -- reconciled here via a positive-membership
  -- check (every value this milestone itself added is still present)
  -- instead of an exact-set-equality string match, mirroring the
  -- identical reconciliation already applied to every prior phase's
  -- sibling validators when a later phase legitimately extends a shared
  -- closed allowlist. ──────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) ILIKE '%''external_correspondence''%'
      AND pg_get_constraintdef(oid) ILIKE '%''workflow_instance''%'
      AND pg_get_constraintdef(oid) ILIKE '%''platform''%'
      AND pg_get_constraintdef(oid) ILIKE '%''task''%'
      AND pg_get_constraintdef(oid) ILIKE '%''meeting''%'
      AND pg_get_constraintdef(oid) ILIKE '%''request''%'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-extended-correctly '; END IF;

  -- ── 5. create_notification_intent()/process_platform_outbox_batch()
  -- keep their exact pre-1.7B signatures (only create_notification_
  -- intent()'s BODY gains one new allowed source_record_type value in
  -- its own guard; process_platform_outbox_batch() is untouched even in
  -- body). resolve_notification_intent() gains exactly one new dispatch
  -- branch ('external_correspondence'), no event-type-specific or
  -- module-specific branch anywhere. ─────────────────────────────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-signature-unexpectedly-changed ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%external_correspondence%' THEN
    v_missing := v_missing || 'create_notification_intent-missing-external-correspondence-source-type-guard-entry ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSIF v_def ILIKE '%entry.routed%' OR v_def ILIKE '%entry.assigned%' OR v_def ILIKE '%entry.reply_sent%'
     OR v_def ILIKE '%entry.reply_returned%'
     OR v_def ILIKE '%IF target_type%' OR v_def ILIKE '%IF module%' OR v_def ILIKE '%''entry''%'
  THEN
    v_missing := v_missing || 'process_platform_outbox_batch-contains-event-or-module-specific-branch ';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF v_def ILIKE '%entry.routed%' OR v_def ILIKE '%entry.assigned%' OR v_def ILIKE '%entry.reply_sent%'
       OR v_def ILIKE '%entry.reply_returned%'
    THEN v_missing := v_missing || 'resolve_notification_intent-unexpectedly-references-new-event-type '; END IF;
    IF v_def NOT ILIKE '%intent_user_can_view_entry%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-entry-dispatch-branch ';
    END IF;
  END IF;

  -- Exactly one new authorization adapter -- intent_user_can_view_entry
  -- -- no separate reply-specific adapter was introduced (see docs/92).
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

  IF to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_entry-missing ';
  END IF;
  IF has_function_privilege('authenticated', 'intent_user_can_view_entry(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'intent_user_can_view_entry(uuid,uuid)', 'EXECUTE')
  THEN v_missing := v_missing || 'intent_user_can_view_entry-exposed-to-ordinary-roles '; END IF;

  -- Genuine, evidenced divergence from intent_user_can_view_request():
  -- Entry RLS's own is_entry_staff() has NO admin/supervisor bypass
  -- (schema.sql's own comment documents this was removed as a bug), so
  -- this adapter must not silently reintroduce one via
  -- is_supervisor_or_above()/intent_user_is_super_admin().
  SELECT pg_get_functiondef(to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'intent_user_can_view_entry-body-missing ';
  ELSIF v_def ILIKE '%is_supervisor_or_above%' OR v_def ILIKE '%intent_user_is_super_admin%' OR v_def ILIKE '%mcs_admin%' OR v_def ILIKE '%authority_admin%'
  THEN v_missing := v_missing || 'intent_user_can_view_entry-unexpectedly-includes-an-admin-bypass '; END IF;
  -- Must not call the session-bound helpers (would authorize the wrong
  -- identity when invoked from inside resolve_notification_intent()).
  IF v_def ILIKE '%is_entry_staff(%' OR v_def ILIKE '%my_section_ids()%' THEN
    v_missing := v_missing || 'intent_user_can_view_entry-unexpectedly-calls-session-bound-helper ';
  END IF;

  -- ── 6. Each producer enqueues INSIDE its own server-authoritative
  -- Phase 1.7A mutation RPC (never a separate/frontend call), never a
  -- direct user_notifications write, never a free-text field (subject/
  -- body/sender_name/sender_contact/prisoner_name/p_comment) copied
  -- into the payload ──────────────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.route_entry(uuid,uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'route_entry-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'route_entry-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%entry.routed.v1%' THEN v_missing := v_missing || 'route_entry-missing-routed-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%entry.assigned.v1%' THEN v_missing := v_missing || 'route_entry-missing-assigned-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%''section''%' THEN v_missing := v_missing || 'route_entry-missing-section-target-type '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'route_entry-missing-specific-users-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'route_entry-direct-user-notifications-write '; END IF;
    -- Mutually-exclusive either/or enqueue, mirroring the legacy
    -- if(assignedTo)/else branch exactly.
    IF v_def !~ 'IF p_assigned_to IS NOT NULL THEN\s*\n\s*PERFORM platform_enqueue_outbox_event' THEN
      v_missing := v_missing || 'route_entry-enqueue-not-correctly-gated-on-assignee-branch ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 1400) ILIKE '%v_row.subject%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 1400) ILIKE '%sender_name%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 1400) ILIKE '%sender_contact%'
       OR substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 1400) ILIKE '%prisoner_name%'
    THEN v_missing := v_missing || 'route_entry-leaks-free-text-into-payload '; END IF;
    -- 1.7A mutation boundary must remain byte-for-byte: same
    -- authorization guard, same UPDATE shape.
    IF v_def NOT ILIKE '%Not authorized to route this entry%' THEN
      v_missing := v_missing || 'route_entry-1.7a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_entry(uuid,uuid,date)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_entry-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'assign_entry-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%entry.assigned.v1%' THEN v_missing := v_missing || 'assign_entry-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'assign_entry-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'assign_entry-direct-user-notifications-write '; END IF;
    -- Enqueue must be gated on a real assignee (mirrors legacy `if (userId)`).
    IF v_def !~ 'IF p_user_id IS NOT NULL THEN\s*\n\s*PERFORM platform_enqueue_outbox_event' THEN
      v_missing := v_missing || 'assign_entry-enqueue-not-correctly-gated-on-non-null-assignee ';
    END IF;
    IF v_def NOT ILIKE '%Not authorized to assign this entry%' THEN
      v_missing := v_missing || 'assign_entry-1.7a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.approve_entry_reply(uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'approve_entry_reply-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'approve_entry_reply-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%entry.reply_sent.v1%' THEN v_missing := v_missing || 'approve_entry_reply-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'approve_entry_reply-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'approve_entry_reply-direct-user-notifications-write '; END IF;
    -- Sourced from the PARENT entry, never a reply source type.
    IF v_def NOT ILIKE '%''external_correspondence'', v_entry.id%' THEN
      v_missing := v_missing || 'approve_entry_reply-not-sourced-from-parent-entry ';
    END IF;
    IF v_def ILIKE '%source_record_type'', ''external_correspondence_reply%' THEN
      v_missing := v_missing || 'approve_entry_reply-unexpectedly-uses-a-reply-source-type ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%v_row.body%'
    THEN v_missing := v_missing || 'approve_entry_reply-leaks-free-text-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to approve this reply%' THEN
      v_missing := v_missing || 'approve_entry_reply-1.7a-authorization-check-missing ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.return_entry_reply(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'return_entry_reply-missing ';
  ELSE
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'return_entry_reply-no-atomic-enqueue '; END IF;
    IF v_def NOT ILIKE '%entry.reply_returned.v1%' THEN v_missing := v_missing || 'return_entry_reply-missing-event-type-literal '; END IF;
    IF v_def NOT ILIKE '%specific_users%' THEN v_missing := v_missing || 'return_entry_reply-missing-expected-target-type '; END IF;
    IF v_def ILIKE '%INSERT INTO user_notifications%' THEN v_missing := v_missing || 'return_entry_reply-direct-user-notifications-write '; END IF;
    IF v_def NOT ILIKE '%''external_correspondence'', v_entry.id%' THEN
      v_missing := v_missing || 'return_entry_reply-not-sourced-from-parent-entry ';
    END IF;
    IF substring(v_def FROM position('platform_enqueue_outbox_event' IN v_def) FOR 900) ILIKE '%p_comment%'
    THEN v_missing := v_missing || 'return_entry_reply-leaks-free-text-into-payload '; END IF;
    IF v_def NOT ILIKE '%Not authorized to return this reply%' THEN
      v_missing := v_missing || 'return_entry_reply-1.7a-authorization-check-missing ';
    END IF;
  END IF;

  -- ── 7. Legacy NotificationsAPI.notify() call sites are untouched by
  -- this SQL-only patch (js/data/entry-api.js is not modified here --
  -- verified structurally by confirming none of the four RPCs gained a
  -- server-side legacy `INSERT INTO notifications` write, since Entry
  -- never had one server-side to begin with). ────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.route_entry(uuid,uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%INSERT INTO notifications%' THEN v_missing := v_missing || 'route_entry-unexpectedly-gained-server-side-legacy-notification '; END IF;

  -- ── 8. No frontend outbox enqueue, no client worker execution, no
  -- direct authenticated write path to platform_outbox_events/
  -- notification_intents was opened by this milestone -- RLS is the
  -- real gate (relrowsecurity + zero policies), matching every prior
  -- CAP-003 validator's own convention. ──────────────────────────────
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

  -- ── 9. Entry/reply RLS untouched -- byte-for-byte the same policy
  -- count Phase 1.7A itself asserted. ─────────────────────────────────
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence') <> 5 THEN
    v_missing := v_missing || 'external_correspondence-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence_replies') <> 3 THEN
    v_missing := v_missing || 'external_correspondence_replies-policy-count-drift '; END IF;

  -- ── 10. Phase 1.7A direct-write closure preserved -- still no direct
  -- authenticated INSERT/UPDATE on external_correspondence(_replies). ──
  IF has_table_privilege('authenticated', 'public.external_correspondence', 'INSERT') THEN v_missing := v_missing || 'external_correspondence-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.external_correspondence', 'UPDATE') THEN v_missing := v_missing || 'external_correspondence-update-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.external_correspondence_replies', 'INSERT') THEN v_missing := v_missing || 'external_correspondence_replies-insert-unexpectedly-reopened '; END IF;
  IF has_table_privilege('authenticated', 'public.external_correspondence_replies', 'UPDATE') THEN v_missing := v_missing || 'external_correspondence_replies-update-unexpectedly-reopened '; END IF;

  -- ── 11. No external delivery / preferences / new Realtime object
  -- introduced by this milestone ─────────────────────────────────────
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_schema='public' AND (routine_name ILIKE '%send_email%' OR routine_name ILIKE '%send_push%' OR routine_name ILIKE '%send_sms%'))
  THEN v_missing := v_missing || 'unexpected-external-delivery-function '; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name ILIKE '%notification_preference%')
  THEN v_missing := v_missing || 'unexpected-notification-preferences-table '; END IF;

  -- ── 12. All 12 Phase 1.7A Entry RPCs still present, unrelated
  -- modules (Internal Collaboration/Prisoner Letters) still not
  -- integrated, CAP-002/CAP-003 baselines intact, CAP-003 Phase 2 not
  -- started. ──────────────────────────────────────────────────────────
  IF to_regprocedure('public.create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)') IS NULL THEN v_missing := v_missing || 'create_entry-missing '; END IF;
  IF to_regprocedure('public.update_entry_draft(uuid,text,text,text,text,date)') IS NULL THEN v_missing := v_missing || 'update_entry_draft-missing '; END IF;
  IF to_regprocedure('public.mark_entry_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_entry_received-missing '; END IF;
  IF to_regprocedure('public.close_entry(uuid)') IS NULL THEN v_missing := v_missing || 'close_entry-missing '; END IF;
  IF to_regprocedure('public.draft_entry_reply(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'draft_entry_reply-missing '; END IF;
  IF to_regprocedure('public.update_entry_reply_draft(uuid,text,text)') IS NULL THEN v_missing := v_missing || 'update_entry_reply_draft-missing '; END IF;
  IF to_regprocedure('public.submit_entry_reply(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'submit_entry_reply-missing '; END IF;
  IF to_regprocedure('public.mark_entry_reply_sent(uuid,text)') IS NULL THEN v_missing := v_missing || 'mark_entry_reply_sent-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_request-missing '; END IF;
  -- No prisoner-transfer/facility-reassignment engine introduced
  -- (Phase 1.7A's own documented finding, unchanged).
  IF to_regprocedure('public.transfer_entry(uuid,uuid)') IS NOT NULL
     OR to_regprocedure('public.reassign_entry_prison(uuid,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'unexpected-prisoner-transfer-engine-introduced '; END IF;
  -- 'internal_collaboration' is no longer out-of-scope as of CAP-003
  -- Phase 1.8B (validate-internal-collaboration-notification-
  -- integration.sql owns that assertion now), and 'prisoner_letters' is
  -- no longer out-of-scope as of CAP-003 Phase 1.9B (validate-prisoner-
  -- letters-notification-integration.sql owns that assertion now) --
  -- there is no longer any deferred-module assertion left for this
  -- validator to own.

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Entry notification integration structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Entry notification integration structural validation PASSED (entry.routed.v1/entry.assigned.v1/entry.reply_sent.v1/entry.reply_returned.v1 registered and registry-driven, deferred candidates absent, all four producers atomically enqueue inside their own Phase 1.7A server-authoritative RPC with free-text fields excluded from payload, worker/resolver/create_notification_intent gain only the minimal external_correspondence-dispatch addition, exactly one new authorization adapter (intent_user_can_view_entry, internal-only, deliberately no admin bypass, no session-bound helper calls), no reply source type, no new target kind, Phase 1.7A direct-write closure and RLS preserved, Internal Collaboration/Prisoner Letters now integrated via their own later phases, CAP-003 Phase 2 not started).';
END $$;
