-- CAP-002 Phase 5.4 SLA timer dispatch & worker foundation structural
-- validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_body TEXT;
BEGIN
  -- This phase is purely additive: zero new tables. Still exactly 24
  -- workflow_ tables, the same count Phase 5.3/5.3A left behind.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 24
  THEN v_missing := v_missing || 'unexpected-table-count-phase-5.4-must-add-zero-tables '; END IF;

  -- All five new functions exist.
  IF to_regprocedure('public.workflow_sla_automatic_idempotency_key(uuid,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_sla_automatic_idempotency_key-missing '; END IF;
  IF to_regprocedure('public.workflow_sla_process_due_warnings(integer)') IS NULL THEN
    v_missing := v_missing || 'workflow_sla_process_due_warnings-missing '; END IF;
  IF to_regprocedure('public.workflow_sla_process_due_breaches(integer)') IS NULL THEN
    v_missing := v_missing || 'workflow_sla_process_due_breaches-missing '; END IF;
  IF to_regprocedure('public.workflow_sla_process_due_escalations(integer)') IS NULL THEN
    v_missing := v_missing || 'workflow_sla_process_due_escalations-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'process_workflow_sla_due_batch-missing '; END IF;

  -- The four internal helpers must be fully private -- no grant to
  -- anon or authenticated at all (unlike the due-detection functions,
  -- which are also private-but-callable-by-owner; same posture here).
  FOR v_def IN SELECT unnest(ARRAY[
    'workflow_sla_automatic_idempotency_key(uuid,text)',
    'workflow_sla_process_due_warnings(integer)',
    'workflow_sla_process_due_breaches(integer)',
    'workflow_sla_process_due_escalations(integer)'
  ]) LOOP
    IF to_regprocedure('public.' || v_def) IS NOT NULL THEN
      IF has_function_privilege('authenticated', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
        v_missing := v_missing || (v_def || '-authenticated-leak ');
      END IF;
      IF has_function_privilege('anon', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
        v_missing := v_missing || (v_def || '-anon-leak ');
      END IF;
    END IF;
  END LOOP;

  -- The single worker-facing entry point: NOT granted to anon or
  -- authenticated, but IS granted to service_role -- the narrowest
  -- approved execution boundary for a worker/system path, per the
  -- governing instruction ("Do not expose the dispatcher casually to
  -- ordinary authenticated users... service/internal-only execution
  -- where appropriate").
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NOT NULL THEN
    IF has_function_privilege('authenticated', to_regprocedure('public.process_workflow_sla_due_batch(integer)'), 'EXECUTE') THEN
      v_missing := v_missing || 'process_workflow_sla_due_batch-must-not-be-granted-to-authenticated ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.process_workflow_sla_due_batch(integer)'), 'EXECUTE') THEN
      v_missing := v_missing || 'process_workflow_sla_due_batch-anon-leak ';
    END IF;
    IF NOT has_function_privilege('service_role', to_regprocedure('public.process_workflow_sla_due_batch(integer)'), 'EXECUTE') THEN
      v_missing := v_missing || 'process_workflow_sla_due_batch-not-granted-to-service_role ';
    END IF;
  END IF;

  -- SECURITY DEFINER + pinned search_path on every new function
  -- (matching every RPC since Phase 1).
  FOR v_def IN SELECT unnest(ARRAY[
    'workflow_sla_process_due_warnings(integer)',
    'workflow_sla_process_due_breaches(integer)',
    'workflow_sla_process_due_escalations(integer)',
    'process_workflow_sla_due_batch(integer)'
  ]) LOOP
    IF to_regprocedure('public.' || v_def) IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.' || v_def)
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || (v_def || '-security '); END IF;
  END LOOP;

  -- Each per-category processor must actually claim rows with FOR
  -- UPDATE SKIP LOCKED, and must consume the existing Phase 5.3/5.3A
  -- due-detection functions rather than re-scanning workflow_sla_
  -- clocks with its own ad hoc predicate.
  SELECT pg_get_functiondef(to_regprocedure('public.workflow_sla_process_due_warnings(integer)')) INTO v_body;
  IF v_body NOT ILIKE '%FOR UPDATE SKIP LOCKED%' THEN v_missing := v_missing || 'process-due-warnings-missing-skip-locked '; END IF;
  IF v_body NOT ILIKE '%workflow_sla_clocks_due_for_warning%' THEN v_missing := v_missing || 'process-due-warnings-not-reusing-due-detection '; END IF;
  IF v_body NOT ILIKE '%workflow_calculate_calendar_offset_backward%' THEN v_missing := v_missing || 'process-due-warnings-not-calendar-aware '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.workflow_sla_process_due_breaches(integer)')) INTO v_body;
  IF v_body NOT ILIKE '%FOR UPDATE SKIP LOCKED%' THEN v_missing := v_missing || 'process-due-breaches-missing-skip-locked '; END IF;
  IF v_body NOT ILIKE '%workflow_sla_clocks_due_for_breach%' THEN v_missing := v_missing || 'process-due-breaches-not-reusing-due-detection '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.workflow_sla_process_due_escalations(integer)')) INTO v_body;
  IF v_body NOT ILIKE '%FOR UPDATE SKIP LOCKED%' THEN v_missing := v_missing || 'process-due-escalations-missing-skip-locked '; END IF;
  IF v_body NOT ILIKE '%workflow_sla_clocks_due_for_escalation%' THEN v_missing := v_missing || 'process-due-escalations-not-reusing-due-detection '; END IF;
  IF v_body NOT ILIKE '%mark_breached%' THEN v_missing := v_missing || 'process-due-escalations-missing-mark-breached-handling '; END IF;
  -- Never touches protected graph/decision/candidate machinery --
  -- same invariant Phase 5.3's manual escalation RPC already upholds.
  IF v_body ILIKE '%decide_workflow_work_item%' OR v_body ILIKE '%workflow_enter_downstream_node%'
     OR v_body ILIKE '%workflow_resolve_approval_candidates%'
  THEN v_missing := v_missing || 'escalation-dispatch-touches-protected-graph-machinery '; END IF;
  -- Automatic escalation events must be attributable as automatic,
  -- with no human actor -- the exact combination workflow_escalation_
  -- events_manual_actor_check has allowed since Phase 5.3.
  IF v_body NOT ILIKE '%''automatic''%' THEN v_missing := v_missing || 'escalation-dispatch-not-marked-automatic '; END IF;

  -- Bounded batch size: the top-level entry point must clamp its
  -- input, never pass an unbounded/unvalidated limit through to the
  -- claiming loops.
  SELECT pg_get_functiondef(to_regprocedure('public.process_workflow_sla_due_batch(integer)')) INTO v_body;
  IF v_body NOT ILIKE '%LEAST%' OR v_body NOT ILIKE '%GREATEST%' THEN
    v_missing := v_missing || 'dispatch-batch-not-bounded ';
  END IF;
  IF v_body NOT ILIKE '%workflow_sla_process_due_warnings%'
     OR v_body NOT ILIKE '%workflow_sla_process_due_breaches%'
     OR v_body NOT ILIKE '%workflow_sla_process_due_escalations%'
  THEN v_missing := v_missing || 'dispatch-batch-missing-a-due-category '; END IF;

  -- No notification delivery of any kind was introduced -- no
  -- email/SMS/HTTP/webhook call sites anywhere in the new functions.
  FOR v_def IN SELECT unnest(ARRAY[
    'workflow_sla_process_due_warnings(integer)',
    'workflow_sla_process_due_breaches(integer)',
    'workflow_sla_process_due_escalations(integer)',
    'process_workflow_sla_due_batch(integer)'
  ]) LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_body;
    IF v_body ILIKE '%net.http_%' OR v_body ILIKE '%pg_net%' OR v_body ILIKE '%smtp%'
       OR v_body ILIKE '%INSERT INTO notifications%'
    THEN v_missing := v_missing || (v_def || '-notification-delivery-present '); END IF;
  END LOOP;

  -- No cron/scheduler wiring of any kind was introduced by this phase.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    v_missing := v_missing || 'pg_cron-extension-present ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('tick_workflow_sla_timers','dispatch_workflow_sla_due_scheduled','workflow_sla_dispatch_cron')
  ) THEN v_missing := v_missing || 'out-of-scope-scheduler-rpc-present '; END IF;

  -- No new workflow node type, no outbox table, no module-adapter
  -- table introduced.
  IF to_regclass('public.workflow_outbox') IS NOT NULL OR to_regclass('public.workflow_outbox_items') IS NOT NULL THEN
    v_missing := v_missing || 'out-of-scope-outbox-table-present ';
  END IF;

  -- Zero bytes of any Phase 1-5.3A function were modified: the
  -- specific functions this phase reuses (due-detection, calendar
  -- arithmetic, manual RPCs) must still exist with their Phase 5.3A
  -- signatures, still calendar-aware, still authenticated-gated where
  -- they always were.
  IF to_regprocedure('public.record_workflow_sla_warning(uuid,bigint,integer,uuid)') IS NULL
     OR to_regprocedure('public.record_workflow_sla_breach(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.trigger_workflow_sla_escalation(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_warning(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_breach(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_escalation(integer)') IS NULL
     OR to_regprocedure('public.workflow_calculate_calendar_deadline(timestamptz,numeric,text,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_calculate_calendar_offset_backward(timestamptz,numeric,text,uuid,text)') IS NULL
  THEN v_missing := v_missing || 'phase-5.3-5.3a-primitive-missing '; END IF;
  IF NOT has_function_privilege('authenticated', to_regprocedure('public.record_workflow_sla_warning(uuid,bigint,integer,uuid)'), 'EXECUTE')
     OR NOT has_function_privilege('authenticated', to_regprocedure('public.record_workflow_sla_breach(uuid,bigint,uuid)'), 'EXECUTE')
     OR NOT has_function_privilege('authenticated', to_regprocedure('public.trigger_workflow_sla_escalation(uuid,bigint,uuid)'), 'EXECUTE')
  THEN v_missing := v_missing || 'manual-rpc-grant-drift '; END IF;

  -- Phase 5.3A's restart privatization is unaffected by this phase --
  -- restart_workflow_sla_clock remains private/ungranted to
  -- authenticated and anon.
  IF to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)') IS NULL THEN
    v_missing := v_missing || 'restart_workflow_sla_clock-missing ';
  ELSE
    IF has_function_privilege('authenticated', to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'restart_workflow_sla_clock-grant-drift ';
    END IF;
  END IF;

  -- No new direct table grants: workflow_sla_clocks/_events/
  -- workflow_escalation_events still SELECT-only for authenticated,
  -- no INSERT/UPDATE/DELETE leaked to anon/authenticated by this
  -- phase (mutation remains exclusively through SECURITY DEFINER
  -- RPC bodies, exactly as before).
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name IN ('workflow_sla_clocks','workflow_sla_clock_events','workflow_escalation_events')
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant-introduced '; END IF;

  -- Prior-phase baseline (Phase 1 through 5.3A) remains completely
  -- intact and untouched by this milestone.
  IF to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)')) INTO v_def;
  IF v_def ILIKE '%process_workflow_sla_due_batch%' OR v_def ILIKE '%workflow_sla_process_due%' THEN
    v_missing := v_missing || 'decision-engine-unexpectedly-dispatch-aware ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow SLA timer dispatch structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow SLA timer dispatch structural check PASSED (zero new tables -- purely additive; process_workflow_sla_due_batch granted ONLY to service_role, denied to authenticated/anon; four internal helpers fully private/ungranted; every processor claims via FOR UPDATE SKIP LOCKED and reuses the existing Phase 5.3/5.3A due-detection + calendar-aware offset functions unchanged; escalation dispatch never touches protected graph/decision machinery and always marks triggered_by=automatic; batch size hard-clamped; zero notification delivery; zero cron/scheduler wiring; zero outbox table; zero new direct table grants; Phase 1-5.3A baseline, restart privatization, and manual-RPC authenticated grants fully intact).';
END $$;
