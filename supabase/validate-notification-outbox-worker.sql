-- CAP-003 Phase 1.3 notification outbox worker structural validator
-- (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── Worker entry point exists, service/internal-only ─────────────
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'process_platform_outbox_batch-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.process_platform_outbox_batch(integer,text)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'process_platform_outbox_batch-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'process_platform_outbox_batch-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.process_platform_outbox_batch(integer,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'process_platform_outbox_batch-not-granted-to-service_role ';
    END IF;

    SELECT pg_get_functiondef(to_regprocedure('public.process_platform_outbox_batch(integer,text)')) INTO v_def;

    -- ── Bounded batch limit enforced (hard clamp, not merely a
    -- default) ────────────────────────────────────────────────────
    IF v_def !~* 'LEAST\s*\(\s*GREATEST' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-hard-clamp ';
    END IF;
    IF v_def !~* '200' THEN v_missing := v_missing || 'process_platform_outbox_batch-missing-documented-hard-max '; END IF;

    -- ── SKIP LOCKED claiming ─────────────────────────────────────
    IF v_def !~* 'FOR UPDATE SKIP LOCKED' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-skip-locked ';
    END IF;

    -- ── Re-derives eligibility from the locked row (never trusts the
    -- pre-lock candidate snapshot alone) ────────────────────────────
    IF v_def !~* 'status\s*<>\s*''pending''' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-post-lock-status-revalidation ';
    END IF;

    -- ── Reuses Phase 1.2's resolver/creation primitives verbatim --
    -- no duplicate recipient-resolution implementation ─────────────
    IF v_def !~* 'create_notification_intent' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-does-not-call-create_notification_intent ';
    END IF;
    IF v_def !~* 'resolve_notification_intent' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-does-not-call-resolve_notification_intent ';
    END IF;

    -- ── Retry state: attempt_count incremented, next_attempt_at
    -- advanced, terminal dead_letter transition present ────────────
    IF v_def !~* 'attempt_count\s*\+\s*1' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-attempt-increment ';
    END IF;
    IF v_def !~* 'dead_letter' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-dead-letter-transition ';
    END IF;
    IF v_def !~* 'platform_outbox_worker_backoff_interval' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-backoff-usage ';
    END IF;

    -- ── Per-item failure isolation: a BEGIN/EXCEPTION block inside
    -- the claim loop ────────────────────────────────────────────────
    IF v_def !~* 'EXCEPTION\s+WHEN\s+OTHERS' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-missing-per-item-exception-handling ';
    END IF;

    -- ── Immutable outbox event-envelope fields never touched by the
    -- worker's own UPDATE statements (only mutable processing-state
    -- columns) ──────────────────────────────────────────────────────
    IF v_def ~* 'SET[^;]*\bevent_type\s*=' OR v_def ~* 'SET[^;]*\bpayload\s*=' OR v_def ~* 'SET[^;]*\bidempotency_key\s*=' THEN
      v_missing := v_missing || 'process_platform_outbox_batch-touches-immutable-envelope-fields ';
    END IF;
  END IF;

  -- ── Backoff is deterministic (pure function of attempt_count, no
  -- randomness) and bounded ───────────────────────────────────────
  IF to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)') IS NULL THEN
    v_missing := v_missing || 'platform_outbox_worker_backoff_interval-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)')) INTO v_def;
    IF v_def ~* 'random\s*\(' THEN v_missing := v_missing || 'backoff-uses-non-deterministic-random '; END IF;
    IF v_def !~* 'LEAST' THEN v_missing := v_missing || 'backoff-missing-documented-cap '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.platform_outbox_worker_backoff_interval(integer)'), 'EXECUTE')
    THEN v_missing := v_missing || 'backoff-exposed-to-ordinary-roles '; END IF;
  END IF;

  -- ── Candidate discovery helper: private, index-backed pre-filter ──
  IF to_regprocedure('public.platform_outbox_events_due_for_processing(integer)') IS NULL THEN
    v_missing := v_missing || 'platform_outbox_events_due_for_processing-missing ';
  ELSE
    IF has_function_privilege('authenticated', to_regprocedure('public.platform_outbox_events_due_for_processing(integer)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.platform_outbox_events_due_for_processing(integer)'), 'EXECUTE')
    THEN v_missing := v_missing || 'platform_outbox_events_due_for_processing-exposed-to-ordinary-roles '; END IF;
  END IF;

  -- ── Dead-letter replay: narrow, service-only, only touches a
  -- genuinely dead_letter row ───────────────────────────────────────
  IF to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)') IS NULL THEN
    v_missing := v_missing || 'replay_dead_lettered_outbox_event-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'replay_dead_lettered_outbox_event-security-drift '; END IF;
    IF has_function_privilege('authenticated', to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'replay_dead_lettered_outbox_event-exposed-to-ordinary-roles '; END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'replay_dead_lettered_outbox_event-not-granted-to-service_role ';
    END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)')) INTO v_def;
    IF v_def !~* 'status\s*=\s*''dead_letter''' THEN
      v_missing := v_missing || 'replay_dead_lettered_outbox_event-does-not-scope-to-dead-letter-rows ';
    END IF;
  END IF;

  -- ── No new tables/columns: this milestone is purely additive on
  -- top of Phase 1.1's own processing-state columns ─────────────────
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='attempt_count'
  ) THEN v_missing := v_missing || 'phase1.1-attempt_count-column-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='platform_outbox_events' AND column_name='next_attempt_at'
  ) THEN v_missing := v_missing || 'phase1.1-next_attempt_at-column-missing '; END IF;

  -- ── Immutable outbox event-envelope fields remain protected by
  -- Phase 1.1's own trigger (unaffected by this milestone) ──────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.platform_outbox_events')
      AND tgname = 'trg_platform_outbox_events_immutability' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'phase1.1-outbox-immutability-trigger-missing '; END IF;

  -- ── No notification delivery channel, no Realtime cutover, no
  -- module integration beyond CAP-003 Phase 1.4's own explicitly
  -- approved pilot (assign_task() -- docs/85, its own structural
  -- validator is validate-notification-module-integration-foundation.sql) ──
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname ILIKE ANY (ARRAY['%send_email%','%send_push%','%send_sms%','%deliver_notification%','%realtime_cutover%'])
  ) THEN v_missing := v_missing || 'unexpected-delivery-or-realtime-object-exists '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN (
        'submit_request_for_approval','approve_request','route_request','create_meeting',
        'log_entry','submit_prisoner_letter'
      )
      AND pg_get_functiondef(p.oid) ILIKE '%platform_enqueue_outbox_event%'
  ) THEN v_missing := v_missing || 'unexpected-module-integration-detected '; END IF;

  -- ── Legacy notification fixes (1.0A/1.0B) remain intact ──────────
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'legacy-create_legacy_notification-missing ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'legacy-notif_select-drift '; END IF;

  -- ── Phase 1.1/1.2 baselines untouched ────────────────────────────
  IF to_regclass('public.platform_outbox_events') IS NULL THEN v_missing := v_missing || 'phase1.1-platform_outbox_events-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-user_notifications-missing '; END IF;
  IF to_regclass('public.notification_intents') IS NULL THEN v_missing := v_missing || 'phase1.2-notification_intents-missing '; END IF;
  IF to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-create_notification_intent-missing '; END IF;
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-resolve_notification_intent-missing '; END IF;

  -- ── CAP-002 baseline untouched ────────────────────────────────────
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_participants') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification outbox worker structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification outbox worker structural check PASSED (process_platform_outbox_batch is SECURITY DEFINER/pinned search_path/service_role-only with a hard-clamped [1,200] batch limit, FOR UPDATE SKIP LOCKED per-candidate claiming with post-lock status revalidation, per-item BEGIN/EXCEPTION failure isolation, reuses create_notification_intent/resolve_notification_intent verbatim with zero duplicate recipient-resolution logic, never touches immutable outbox envelope fields; deterministic bounded backoff with zero randomness; dead-letter transition and scoped replay both present; candidate-discovery helper private; zero new tables/columns beyond Phase 1.1''s own processing-state columns; zero delivery/Realtime/module-integration objects exist yet; Phase 1.0A/1.0B/1.1/1.2 and CAP-002 baselines all intact).';
END $$;
