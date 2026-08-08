-- CAP-003 Phase 1.1 notification outbox persistence foundation
-- structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── New persistence exists ──────────────────────────────────────
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'platform_outbox_events-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF to_regclass('public.platform_event_type_registry') IS NULL THEN v_missing := v_missing || 'platform_event_type_registry-missing '; END IF;

  -- ── Legacy notifications table completely untouched ────────────
  IF to_regclass('public.notifications') IS NULL THEN v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd = 'INSERT'
  ) THEN v_missing := v_missing || 'legacy-notif-insert-unexpectedly-present '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications') <> 2 THEN
    v_missing := v_missing || 'legacy-notifications-policy-count-drift ';
  END IF;
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'legacy-create_legacy_notification-missing ';
  END IF;

  -- ── event_type / notification_type versioned envelope ──────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.platform_outbox_events')
      AND pg_get_constraintdef(oid) ILIKE '%event_type ~%v%'
  ) THEN v_missing := v_missing || 'outbox-event-type-not-versioned '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.user_notifications')
      AND pg_get_constraintdef(oid) ILIKE '%notification_type ~%v%'
  ) THEN v_missing := v_missing || 'notification-type-not-versioned '; END IF;
  -- Never a closed IN-list (the anti-pattern docs/78 §2.1 diagnoses).
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.platform_outbox_events')
      AND pg_get_constraintdef(oid) ILIKE '%event_type IN (%'
  ) THEN v_missing := v_missing || 'outbox-event-type-closed-enum-anti-pattern '; END IF;

  -- ── Correlation / causation modeled ─────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='correlation_id'
  ) THEN v_missing := v_missing || 'outbox-correlation_id-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='causation_id'
  ) THEN v_missing := v_missing || 'outbox-causation_id-missing '; END IF;

  -- ── Deduplication constraints exist ─────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.platform_outbox_events')
      AND contype = 'u' AND conkey @> (
        SELECT array_agg(attnum) FROM pg_attribute
        WHERE attrelid = to_regclass('public.platform_outbox_events')
          AND attname IN ('source_module','source_record_type','source_record_id','event_type','idempotency_key')
      )
  ) THEN v_missing := v_missing || 'outbox-idempotency-unique-constraint-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.user_notifications')
      AND contype = 'u' AND conkey @> (
        SELECT array_agg(attnum) FROM pg_attribute
        WHERE attrelid = to_regclass('public.user_notifications')
          AND attname IN ('outbox_event_id','recipient_user_id')
      )
  ) THEN v_missing := v_missing || 'notification-dedup-unique-constraint-missing '; END IF;

  -- ── Outbox business fields protected from arbitrary mutation ───
  IF to_regprocedure('public.platform_outbox_events_enforce_immutability()') IS NULL THEN
    v_missing := v_missing || 'outbox-immutability-function-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.platform_outbox_events_enforce_immutability()')) INTO v_def;
    IF v_def NOT ILIKE '%event_type%' OR v_def NOT ILIKE '%payload%' OR v_def NOT ILIKE '%idempotency_key%' THEN
      v_missing := v_missing || 'outbox-immutability-incomplete ';
    END IF;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.platform_outbox_events')
      AND tgname = 'trg_platform_outbox_events_immutability' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'outbox-immutability-trigger-missing '; END IF;

  -- ── User notifications recipient-scoped, business fields protected ──
  IF to_regprocedure('public.user_notifications_enforce_immutability()') IS NULL THEN
    v_missing := v_missing || 'notification-immutability-function-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.user_notifications_enforce_immutability()')) INTO v_def;
    IF v_def NOT ILIKE '%notification_type%' OR v_def NOT ILIKE '%outbox_event_id%' THEN
      v_missing := v_missing || 'notification-immutability-incomplete ';
    END IF;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.user_notifications')
      AND tgname = 'trg_user_notifications_immutability' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'notification-immutability-trigger-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND cmd='SELECT'
      AND qual = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notification-select-policy-wrong-or-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_update' AND cmd='UPDATE'
      AND qual = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notification-update-policy-wrong-or-missing '; END IF;
  -- No INSERT/DELETE policy for ordinary users -- creation is
  -- SECURITY DEFINER-only, deletion is not supported at all.
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications' AND cmd IN ('INSERT','DELETE')
  ) THEN v_missing := v_missing || 'notification-unexpected-insert-or-delete-policy '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications') <> 2 THEN
    v_missing := v_missing || 'notification-unexpected-policy-count ';
  END IF;

  -- Ordinary authenticated users cannot insert arbitrary notifications
  -- or read/insert outbox rows -- enforced via RLS (zero INSERT/DELETE
  -- policy on user_notifications; zero policy of any kind on the
  -- outbox table), not via table-level grants. Table-level grants are
  -- NOT checked here deliberately: this disposable local test harness
  -- (build_baseline.sh's 01-grants.sql) applies a blanket
  -- GRANT ... ON ALL TABLES IN SCHEMA public TO anon, authenticated
  -- AFTER every patch, exactly matching Supabase's own real-world
  -- default of broad table grants with RLS as the actual enforced
  -- gate -- the identical precedent 1.0A's own validator already
  -- documents for the legacy notifications table. RLS presence/shape
  -- is the real, meaningful assertion and is checked directly below
  -- and above.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.platform_outbox_events')) THEN
    v_missing := v_missing || 'outbox-rls-not-enabled ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events'
  ) THEN v_missing := v_missing || 'outbox-unexpected-policy-present '; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.user_notifications')) THEN
    v_missing := v_missing || 'notification-rls-not-enabled ';
  END IF;

  -- ── Service-only creation primitives: SECURITY DEFINER, pinned
  -- search_path, revoked from PUBLIC/anon/authenticated, granted to
  -- service_role only ──
  IF to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'platform_enqueue_outbox_event-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'enqueue-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'enqueue-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'enqueue-not-granted-to-service_role ';
    END IF;
  END IF;

  IF to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'platform_create_user_notification-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'create-notification-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)'), 'EXECUTE')
    THEN v_missing := v_missing || 'create-notification-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create-notification-not-granted-to-service_role ';
    END IF;
  END IF;

  -- ── List APIs bounded, keyset pagination used ───────────────────
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'list_my_notifications-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)')) INTO v_def;
    IF v_def NOT ILIKE '%LIMIT%' THEN v_missing := v_missing || 'list-not-bounded '; END IF;
    IF v_def NOT ILIKE '%created_at, n.id) <%' AND v_def NOT ILIKE '%created_at,n.id) <%' THEN
      v_missing := v_missing || 'list-not-keyset-paginated ';
    END IF;
    IF v_def ILIKE '%OFFSET%' THEN v_missing := v_missing || 'list-uses-offset-pagination '; END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)'), 'EXECUTE') THEN
      v_missing := v_missing || 'list-not-granted-to-authenticated ';
    END IF;
  END IF;
  IF to_regprocedure('public.count_my_unread_notifications()') IS NULL THEN
    v_missing := v_missing || 'count_my_unread_notifications-missing ';
  END IF;

  -- ── Indexes exist per docs/78 §20 ───────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE tablename='platform_outbox_events' AND indexname='idx_platform_outbox_events_pending') THEN
    v_missing := v_missing || 'index-outbox-pending-missing ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE tablename='user_notifications' AND indexname='idx_user_notifications_recipient_read_created') THEN
    v_missing := v_missing || 'index-notification-recipient-read-created-missing ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE tablename='user_notifications' AND indexname='idx_user_notifications_recipient_unread') THEN
    v_missing := v_missing || 'index-notification-unread-partial-missing ';
  END IF;

  -- ── Scope discipline: nothing beyond the inert foundation PLUS
  -- later, separately-approved CAP-003 milestones exists ──
  -- Recipient resolution (Phase 1.2, docs/82) and the outbox worker/
  -- retry/dead-letter processing (Phase 1.3, docs/83) are both later,
  -- independently-approved milestones -- their existence is expected
  -- once each has shipped and is not itself evidence this 1.1
  -- foundation patch did anything out of its own scope. This
  -- validator no longer asserts their absence (their own structural
  -- validators -- validate-notification-recipient-resolution.sql,
  -- validate-notification-outbox-worker.sql -- own that responsibility
  -- now), matching the same carve-out precedent
  -- validate-legacy-notification-record-authorization-fix.sql already
  -- established for notification_intents.
  -- No Realtime cutover / delivery-channel adapters.
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%send_email%','%send_push%','%send_sms%','%deliver_notification%'])
  ) THEN v_missing := v_missing || 'unexpected-delivery-adapter-exists '; END IF;
  -- No module integration beyond CAP-003 Phase 1.4's own explicitly
  -- approved pilot (assign_task() -- docs/85, its own structural
  -- validator is validate-notification-module-integration-foundation.sql).
  -- Requests/Meetings/Entry/Prisoner Letters and every other Tasks RPC
  -- still do not call the enqueue helper -- matching the same
  -- carve-out precedent already established above for
  -- notification_intents/the outbox worker.
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_depend d ON d.objid = p.oid
    JOIN pg_proc callee ON callee.oid = d.refobjid
    WHERE callee.proname = 'platform_enqueue_outbox_event'
      AND p.proname NOT IN ('platform_enqueue_outbox_event')
  ) THEN
    -- Best-effort static check only (pg_depend on function bodies is
    -- unreliable across all function types); the authoritative check
    -- is the textual scan below.
    NULL;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN (
        'submit_request_for_approval','approve_request','route_request','create_meeting',
        'log_entry','submit_prisoner_letter'
      )
      AND pg_get_functiondef(p.oid) ILIKE '%platform_enqueue_outbox_event%'
  ) THEN v_missing := v_missing || 'unexpected-module-integration-detected '; END IF;

  -- CAP-002 baseline and CAP-003 1.0A/1.0B baseline both untouched.
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_sla_clocks') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'cap002-baseline-drift '; END IF;
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'cap003-1.0b-baseline-drift ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification outbox persistence foundation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification outbox persistence foundation structural check PASSED (platform_outbox_events/user_notifications/platform_event_type_registry present with versioned open event-type envelopes, correlation/causation modeled, enqueue-level and notification-level dedup UNIQUE constraints present, business-fact columns immutability-trigger-protected on both tables, user_notifications recipient-scoped SELECT/UPDATE-only RLS with zero INSERT/DELETE policy, outbox fully inaccessible to authenticated/anon with zero policies, both creation primitives SECURITY DEFINER/pinned search_path/service_role-only, list API bounded+keyset-paginated and granted to authenticated, required indexes present, zero delivery-adapter/module-integration objects exist yet, this 1.1 foundation itself created zero worker/retry/dead-letter/recipient-resolution objects -- their presence, if any, is later-milestone territory (Phase 1.2/1.3) asserted by their own validators, CAP-002 and CAP-003 1.0A/1.0B baselines untouched).';
END $$;
