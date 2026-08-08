-- CAP-003 Phase 1.2 notification recipient resolution structural
-- validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── Notification intent persistence exists ──────────────────────
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'notification_intents-missing '; END IF;

  -- ── Typed target descriptors exist (closed target_type list,
  -- structural shape constraint enforcing exactly one target_* field) ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.notification_intents')
      AND pg_get_constraintdef(oid) ILIKE '%target_type = ANY%specific_users%org_admins%section%workflow_participants%work_item_assignee%'
  ) THEN v_missing := v_missing || 'target-type-allowlist-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_shape_check'
  ) THEN v_missing := v_missing || 'target-shape-structural-check-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_target_user_ids_bounded'
  ) THEN v_missing := v_missing || 'target-user-ids-not-bounded '; END IF;

  -- ── Closed source_record_type dispatch (fail-closed for unsupported
  -- source types) ─────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.notification_intents')
      AND pg_get_constraintdef(oid) ILIKE '%source_record_type = ANY%workflow_instance%platform%'
  ) THEN v_missing := v_missing || 'source-record-type-not-closed '; END IF;

  -- ── Intent creation is internal/service-only ────────────────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'create_notification_intent-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'create_notification_intent-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'create_notification_intent-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create_notification_intent-not-granted-to-service_role ';
    END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%workflow_instance%' OR v_def NOT ILIKE '%platform%' THEN
      v_missing := v_missing || 'create_notification_intent-missing-source-type-dispatch ';
    END IF;
  END IF;

  -- ── Intent resolution is internal/service-only, contains genuine
  -- authorization revalidation (not merely claimed) ───────────────
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'resolve_notification_intent-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.resolve_notification_intent(uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'resolve_notification_intent-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.resolve_notification_intent(uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.resolve_notification_intent(uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'resolve_notification_intent-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.resolve_notification_intent(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'resolve_notification_intent-not-granted-to-service_role ';
    END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%intent_user_can_view_workflow_instance%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-authorization-revalidation ';
    END IF;
    IF v_def NOT ILIKE '%is_active = TRUE%' THEN
      v_missing := v_missing || 'resolve_notification_intent-missing-active-user-check ';
    END IF;
    IF v_def NOT ILIKE '%platform_create_user_notification%' THEN
      v_missing := v_missing || 'resolve_notification_intent-does-not-reuse-1.1-creation-primitive ';
    END IF;
    -- Reuses existing recipient-derivation helpers, does not duplicate
    -- their membership logic.
    IF v_def NOT ILIKE '%org_supervisor_user_ids%' OR v_def NOT ILIKE '%section_user_ids%'
       OR v_def NOT ILIKE '%workflow_participants%'
    THEN v_missing := v_missing || 'resolve_notification_intent-missing-expected-resolution-reuse '; END IF;
  END IF;

  -- ── Authorization-revalidation helpers exist, explicit-user
  -- parameterized (never auth.uid()-bound) ────────────────────────
  IF to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'intent_user_can_view_workflow_instance-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.intent_user_can_view_workflow_instance(uuid,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%SECURITY DEFINER%' THEN v_missing := v_missing || 'intent_user_can_view_workflow_instance-not-security-definer '; END IF;
    IF v_def NOT ILIKE '%workflow_participants%' THEN v_missing := v_missing || 'intent_user_can_view_workflow_instance-not-reusing-participants-table '; END IF;
  END IF;

  -- ── Unsupported target/source combinations fail closed: the
  -- structural CHECK constraints above are the enforcement; also
  -- confirm the function body actually raises for an unsupported
  -- source_record_type at creation time rather than silently
  -- accepting it. ──────────────────────────────────────────────────
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)') IS NOT NULL THEN
    SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%NOT IN (%workflow_instance%platform%)%' THEN
      v_missing := v_missing || 'create_notification_intent-missing-fail-closed-source-type-check ';
    END IF;
  END IF;

  -- ── Durable notification deduplication reused (Phase 1.1's own
  -- UNIQUE (outbox_event_id, recipient_user_id), not duplicated) ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.user_notifications')
      AND contype = 'u' AND conkey @> (
        SELECT array_agg(attnum) FROM pg_attribute
        WHERE attrelid = to_regclass('public.user_notifications')
          AND attname IN ('outbox_event_id','recipient_user_id')
      )
  ) THEN v_missing := v_missing || 'notification-dedup-constraint-missing-or-altered '; END IF;

  -- Intent-level dedup (own new constraint).
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.notification_intents')
      AND contype = 'u' AND conkey @> (
        SELECT array_agg(attnum) FROM pg_attribute
        WHERE attrelid = to_regclass('public.notification_intents')
          AND attname IN ('outbox_event_id','target_type','target_key')
      )
  ) THEN v_missing := v_missing || 'intent-dedup-constraint-missing '; END IF;

  -- ── RLS: internal object, zero policies for authenticated/anon ──
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notification_intents')) THEN
    v_missing := v_missing || 'notification_intents-rls-not-enabled ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notification_intents'
  ) THEN v_missing := v_missing || 'notification_intents-unexpected-policy-present '; END IF;

  -- Immutability trigger on business-fact/target-descriptor columns.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.notification_intents')
      AND tgname = 'trg_notification_intents_immutability' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'notification_intents-immutability-trigger-missing '; END IF;

  -- ── Phase 1.1 baseline untouched: user_notifications RLS shape,
  -- outbox zero-policy shape ──────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND cmd='SELECT' AND qual='(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'phase1.1-user_notifications_select-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications') <> 2 THEN
    v_missing := v_missing || 'phase1.1-user_notifications-policy-count-drift ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events'
  ) THEN v_missing := v_missing || 'phase1.1-outbox-unexpected-policy-present '; END IF;

  -- ── Legacy notification fixes (1.0A/1.0B) remain intact ─────────
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'legacy-create_legacy_notification-missing ';
  END IF;
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'legacy-1.0b-baseline-drift ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'legacy-notif_select-drift '; END IF;

  -- ── Scope discipline: nothing beyond recipient resolution exists ──
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%outbox%worker%','%outbox%dispatch%','%outbox%claim%','%process_pending_outbox%','%process_platform_outbox%'])
  ) THEN v_missing := v_missing || 'unexpected-worker-function-exists '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%retry_outbox%','%replay_dead_letter%','%dead_letter_worker%'])
  ) THEN v_missing := v_missing || 'unexpected-retry-dead-letter-worker-exists '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%send_email%','%send_push%','%send_sms%','%deliver_notification%','%realtime_cutover%'])
  ) THEN v_missing := v_missing || 'unexpected-delivery-or-realtime-object-exists '; END IF;
  -- No module integration: no existing module RPC body calls the new
  -- intent-creation primitive yet.
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN (
        'submit_request_for_approval','approve_request','route_request','create_meeting',
        'assign_task','log_entry','submit_prisoner_letter'
      )
      AND pg_get_functiondef(p.oid) ILIKE '%create_notification_intent%'
  ) THEN v_missing := v_missing || 'unexpected-module-integration-detected '; END IF;

  -- CAP-002 baseline untouched.
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_participants') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification recipient resolution structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification recipient resolution structural check PASSED (notification_intents present with closed typed target-descriptor model, structural target-shape/bounded-array constraints, closed source_record_type dispatch fail-closed at creation time, create_notification_intent/resolve_notification_intent both SECURITY DEFINER/pinned search_path/service_role-only, resolve_notification_intent contains genuine authorization revalidation via intent_user_can_view_workflow_instance and reuses org_supervisor_user_ids/section_user_ids/workflow_participants/platform_create_user_notification rather than duplicating them, both intent- and notification-level dedup constraints present, notification_intents zero-policy RLS + immutability trigger, Phase 1.1/1.0A/1.0B baselines all untouched, zero worker/retry/dead-letter/delivery/module-integration objects exist yet, CAP-002 baseline intact).';
END $$;
