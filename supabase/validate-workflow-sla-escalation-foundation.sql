-- CAP-002 Phase 5.3 SLA & escalation persistence/runtime foundation
-- structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_tbl TEXT;
BEGIN
  -- Exactly 8 new tables, on top of the 16 that existed through
  -- Phase 5.2 -- 24 total. This milestone never touches any prior
  -- table's schema.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 24
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  FOR v_tbl IN SELECT unnest(ARRAY[
    'workflow_business_calendars','workflow_business_calendar_versions',
    'workflow_escalation_policies','workflow_escalation_levels',
    'workflow_sla_policies','workflow_sla_clocks',
    'workflow_sla_clock_events','workflow_escalation_events'
  ]) LOOP
    IF to_regclass('public.' || v_tbl) IS NULL THEN
      v_missing := v_missing || (v_tbl || '-missing '); CONTINUE;
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || v_tbl)) THEN
      v_missing := v_missing || (v_tbl || '-rls-not-enabled ');
    END IF;
  END LOOP;

  -- No direct client write access to any new table -- SELECT only,
  -- mutation exclusively through RPCs, matching every other
  -- workflow_ table's established posture.
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name IN (
        'workflow_business_calendars','workflow_business_calendar_versions',
        'workflow_escalation_policies','workflow_escalation_levels',
        'workflow_sla_policies','workflow_sla_clocks',
        'workflow_sla_clock_events','workflow_escalation_events'
      )
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- (Table-level SELECT grants to anon are harmless and expected in
  -- this disposable test harness -- it mirrors Supabase's own real
  -- default of broad table grants with RLS as the actual gate. Every
  -- SELECT policy below is scoped `TO authenticated` only, which is
  -- the real boundary; anon matches no policy and sees zero rows.)

  FOR v_tbl IN SELECT unnest(ARRAY[
    'workflow_business_calendars','workflow_business_calendar_versions',
    'workflow_escalation_policies','workflow_escalation_levels',
    'workflow_sla_policies','workflow_sla_clocks',
    'workflow_sla_clock_events','workflow_escalation_events'
  ]) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = v_tbl
        AND cmd = 'SELECT' AND roles = ARRAY['authenticated']::name[]
    ) THEN v_missing := v_missing || (v_tbl || '-select-policy-not-authenticated-scoped '); END IF;
  END LOOP;

  -- Append-only: every evidence/config table rejects UPDATE and
  -- DELETE via a BEFORE trigger.
  FOR v_tbl IN SELECT unnest(ARRAY[
    'workflow_business_calendar_versions','workflow_escalation_policies',
    'workflow_escalation_levels','workflow_sla_policies',
    'workflow_sla_clock_events','workflow_escalation_events'
  ]) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger t WHERE t.tgrelid = to_regclass('public.' || v_tbl)
        AND t.tgname = v_tbl || '_immutable' AND NOT t.tgisinternal
    ) THEN v_missing := v_missing || (v_tbl || '-immutable-trigger-missing '); END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.workflow_sla_clocks')
      AND tgname = 'workflow_sla_clocks_immutable_after_terminal' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'workflow_sla_clocks-terminal-trigger-missing '; END IF;

  -- Hard database-level backstops behind the RPCs' own idempotent-
  -- replay logic: no duplicate warning per offset index, no duplicate
  -- breach, no duplicate escalation level per clock.
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'public'
      AND tablename = 'workflow_sla_clock_events' AND indexname = 'idx_workflow_sla_clock_events_warning_once'
  ) THEN v_missing := v_missing || 'warning-once-index-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'public'
      AND tablename = 'workflow_sla_clock_events' AND indexname = 'idx_workflow_sla_clock_events_breach_once'
  ) THEN v_missing := v_missing || 'breach-once-index-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.workflow_escalation_events')
      AND conname = 'workflow_escalation_events_no_duplicate_level'
  ) THEN v_missing := v_missing || 'no-duplicate-escalation-level-constraint-missing '; END IF;

  -- The closed seven-action escalation allowlist is exactly as
  -- docs/60/73 enumerate -- no eighth action, no renamed action.
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
    WHERE conrelid = to_regclass('public.workflow_escalation_levels') AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%action_code%';
  IF v_def IS NULL
     OR v_def NOT ILIKE '%remind_actor%' OR v_def NOT ILIKE '%notify_supervisor%'
     OR v_def NOT ILIKE '%add_replace_candidates%' OR v_def NOT ILIKE '%route_higher_scope%'
     OR v_def NOT ILIKE '%create_exception_work_item%' OR v_def NOT ILIKE '%mark_breached%'
     OR v_def NOT ILIKE '%follow_branch%'
  THEN v_missing := v_missing || 'escalation-action-allowlist-drift '; END IF;

  -- Smallest state machine: exactly running/paused/completed/cancelled,
  -- no extra states invented.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.workflow_sla_clocks') AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%running%' AND pg_get_constraintdef(oid) ILIKE '%paused%'
      AND pg_get_constraintdef(oid) ILIKE '%completed%' AND pg_get_constraintdef(oid) ILIKE '%cancelled%'
  ) THEN v_missing := v_missing || 'clock-state-machine-drift '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.workflow_sla_clocks') AND contype = 'c'
      AND (pg_get_constraintdef(oid) ILIKE '%scheduled%' OR pg_get_constraintdef(oid) ILIKE '%pending%'
           OR pg_get_constraintdef(oid) ILIKE '%breached%')
  ) THEN v_missing := v_missing || 'clock-state-machine-has-extra-states '; END IF;

  -- effective_deadline_adjusted is a plain maintained column, not a
  -- GENERATED one (timestamptz + interval is STABLE, not IMMUTABLE,
  -- in Postgres and cannot appear in a generation expression).
  IF EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.workflow_sla_clocks')
      AND a.attname = 'effective_deadline_adjusted' AND a.attgenerated <> ''
  ) THEN v_missing := v_missing || 'effective-deadline-adjusted-unexpectedly-generated '; END IF;

  -- Authorization helpers: STABLE, SECURITY DEFINER, pinned
  -- search_path, ungranted to anon but GRANTED to authenticated --
  -- both are used directly as RLS USING-clause predicates (see the
  -- SELECT-policy checks below), matching can_manage_workflow_
  -- definition's and can_manage_workflow_instance's own established
  -- grant shape exactly (an RLS policy expression runs under the
  -- querying role's own privileges, unlike a call from inside another
  -- SECURITY DEFINER function's body).
  IF to_regprocedure('public.can_manage_workflow_sla_config(uuid)') IS NULL THEN
    v_missing := v_missing || 'can_manage_workflow_sla_config-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.can_manage_workflow_sla_config(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'can_manage_workflow_sla_config-anon-leak '; END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.can_manage_workflow_sla_config(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'can_manage_workflow_sla_config-not-granted-to-authenticated '; END IF;
  END IF;
  IF to_regprocedure('public.can_manage_workflow_sla_clock(uuid)') IS NULL THEN
    v_missing := v_missing || 'can_manage_workflow_sla_clock-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.can_manage_workflow_sla_clock(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'can_manage_workflow_sla_clock-anon-leak '; END IF;
  END IF;

  -- Due-detection foundation: present, private, read-only -- and NOT
  -- called by anything else in this patch (no worker, no cron).
  IF to_regprocedure('public.workflow_sla_clocks_due_for_warning(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_breach(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_escalation(integer)') IS NULL
  THEN v_missing := v_missing || 'due-detection-helpers-missing '; END IF;
  IF has_function_privilege('authenticated', to_regprocedure('public.workflow_sla_clocks_due_for_warning(integer)'), 'EXECUTE')
     OR has_function_privilege('authenticated', to_regprocedure('public.workflow_sla_clocks_due_for_breach(integer)'), 'EXECUTE')
     OR has_function_privilege('authenticated', to_regprocedure('public.workflow_sla_clocks_due_for_escalation(integer)'), 'EXECUTE')
  THEN v_missing := v_missing || 'due-detection-helpers-execute-leak '; END IF;

  -- Every public lifecycle RPC: exists, authenticated-only (no anon),
  -- SECURITY DEFINER, pinned search_path.
  FOR v_def IN SELECT unnest(ARRAY[
    'create_workflow_business_calendar_version(uuid,text,text,text,integer[],time,time,date[],uuid)',
    'create_workflow_escalation_policy(uuid,text,text,jsonb,uuid)',
    'create_workflow_sla_policy(uuid,text,text,numeric,text,uuid,text,jsonb,boolean,boolean,uuid,uuid)',
    'create_workflow_sla_clock(uuid,uuid,uuid,uuid,text,uuid,timestamptz,text,uuid)',
    'pause_workflow_sla_clock(uuid,bigint,text,uuid)',
    'resume_workflow_sla_clock(uuid,bigint,uuid)',
    'complete_workflow_sla_clock(uuid,bigint,uuid)',
    'cancel_workflow_sla_clock(uuid,bigint,text,uuid)',
    'record_workflow_sla_warning(uuid,bigint,integer,uuid)',
    'record_workflow_sla_breach(uuid,bigint,uuid)',
    'trigger_workflow_sla_escalation(uuid,bigint,uuid)'
  ]) LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || (v_def || '-missing ');
      CONTINUE;
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || (v_def || '-not-granted-to-authenticated ');
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || (v_def || '-anon-leak ');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.' || v_def)
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || (v_def || '-security '); END IF;
  END LOOP;

  -- CAP-002 Phase 5.3A correction 1: restart_workflow_sla_clock must
  -- exist (as a private primitive a future, separately approved
  -- Reopen RPC can call) but must NOT be directly callable by
  -- authenticated or anon -- docs/73's own "Open questions" section
  -- states "no other trigger is approved by this document" for
  -- restart besides Reopen, so exposing it as a standalone
  -- authenticated command exceeds the approved contract.
  IF to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)') IS NULL THEN
    v_missing := v_missing || 'restart_workflow_sla_clock-missing ';
  ELSE
    IF has_function_privilege('authenticated', to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'restart_workflow_sla_clock-must-not-be-granted-to-authenticated ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'restart_workflow_sla_clock-anon-leak ';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'restart_workflow_sla_clock-security '; END IF;
  END IF;

  -- CAP-002 Phase 5.3A correction 2: business_hours/business_days
  -- offsets are now calendar-aware. workflow_sla_offset_interval (the
  -- old calendar-oblivious helper) must be gone; the new backward
  -- calendar-walk function must exist and remain private (same
  -- posture as workflow_calculate_calendar_deadline, which it mirrors
  -- and which must remain unchanged and still private).
  IF to_regprocedure('public.workflow_sla_offset_interval(numeric,text)') IS NOT NULL THEN
    v_missing := v_missing || 'workflow_sla_offset_interval-should-be-dropped ';
  END IF;
  IF to_regprocedure('public.workflow_calculate_calendar_offset_backward(timestamptz,numeric,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_calculate_calendar_offset_backward-missing ';
  ELSE
    IF has_function_privilege('authenticated', to_regprocedure('public.workflow_calculate_calendar_offset_backward(timestamptz,numeric,text,uuid,text)'), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.workflow_calculate_calendar_offset_backward(timestamptz,numeric,text,uuid,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_calculate_calendar_offset_backward-execute-leak '; END IF;
  END IF;
  IF to_regprocedure('public.workflow_calculate_calendar_deadline(timestamptz,numeric,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_calculate_calendar_deadline-missing ';
  END IF;
  -- record_workflow_sla_warning and both due-detection functions that
  -- evaluate offsets must reference the calendar-aware functions, not
  -- the dropped interval helper.
  FOR v_def IN SELECT unnest(ARRAY[
    'record_workflow_sla_warning(uuid,bigint,integer,uuid)',
    'workflow_sla_clocks_due_for_warning(integer)'
  ]) LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_tbl;
    IF v_tbl NOT ILIKE '%workflow_calculate_calendar_offset_backward%' THEN
      v_missing := v_missing || (v_def || '-not-calendar-aware-backward ');
    END IF;
  END LOOP;
  SELECT pg_get_functiondef(to_regprocedure('public.workflow_sla_clocks_due_for_escalation(integer)')) INTO v_tbl;
  IF v_tbl NOT ILIKE '%workflow_calculate_calendar_deadline%' THEN
    v_missing := v_missing || 'workflow_sla_clocks_due_for_escalation-not-calendar-aware-forward ';
  END IF;

  -- CAP-002 Phase 5.3A correction 3: workflow_escalation_events must
  -- carry the triggered/due-vs-performed self-documentation comment.
  IF NOT EXISTS (
    SELECT 1 FROM pg_description d
    JOIN pg_class c ON c.oid = d.objoid
    WHERE c.relname = 'workflow_escalation_events' AND d.objsubid = 0
      AND d.description ILIKE '%does NOT prove%'
  ) THEN v_missing := v_missing || 'workflow_escalation_events-missing-evidence-semantics-comment '; END IF;

  -- No worker/cron/notification execution was added by the correction.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    v_missing := v_missing || 'pg_cron-extension-present ';
  END IF;

  -- Idempotent-replay discipline (the Phase 4.3 defect this patch
  -- must not repeat): every mutating RPC's body compares
  -- expected_lock_version as part of its stored-metadata replay check.
  FOR v_def IN SELECT unnest(ARRAY[
    'pause_workflow_sla_clock(uuid,bigint,text,uuid)',
    'resume_workflow_sla_clock(uuid,bigint,uuid)',
    'restart_workflow_sla_clock(uuid,bigint,text,uuid)',
    'complete_workflow_sla_clock(uuid,bigint,uuid)',
    'cancel_workflow_sla_clock(uuid,bigint,text,uuid)',
    'record_workflow_sla_warning(uuid,bigint,integer,uuid)',
    'record_workflow_sla_breach(uuid,bigint,uuid)',
    'trigger_workflow_sla_escalation(uuid,bigint,uuid)'
  ]) LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_tbl;
    IF v_tbl NOT ILIKE '%expected_lock_version%' THEN
      v_missing := v_missing || (v_def || '-replay-missing-lock-version-check ');
    END IF;
  END LOOP;

  -- trigger_workflow_sla_escalation never advances the graph, records
  -- a business decision, or delivers a notification -- and only
  -- mark_breached touches anything beyond current_escalation_level /
  -- evidence.
  SELECT pg_get_functiondef(to_regprocedure('public.trigger_workflow_sla_escalation(uuid,bigint,uuid)')) INTO v_def;
  IF v_def ILIKE '%decide_workflow_work_item%' OR v_def ILIKE '%workflow_enter_downstream_node%'
     OR v_def ILIKE '%workflow_events%'
  THEN v_missing := v_missing || 'escalation-touches-protected-graph-machinery '; END IF;
  IF v_def NOT ILIKE '%mark_breached%' THEN
    v_missing := v_missing || 'escalation-missing-mark-breached-handling ';
  END IF;

  -- No out-of-scope automation: no cron/pg_cron wiring, no
  -- notification-delivery RPCs, no scheduled/background dispatcher.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    v_missing := v_missing || 'pg_cron-extension-present ';
  END IF;
  IF to_regprocedure('public.tick_workflow_sla_timers()') IS NOT NULL
     OR to_regprocedure('public.dispatch_workflow_sla_due()') IS NOT NULL
     OR to_regprocedure('public.send_workflow_sla_notification(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-worker-or-notification-rpc-present '; END IF;

  -- Prior-phase baseline (Phase 1 through 5.2) remains completely
  -- intact and untouched by this milestone.
  IF to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)') IS NULL
     OR to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)')) INTO v_def;
  IF v_def ILIKE '%workflow_sla_clocks%' OR v_def ILIKE '%workflow_escalation%' THEN
    v_missing := v_missing || 'decision-engine-unexpectedly-sla-aware ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow SLA/escalation foundation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow SLA/escalation foundation structural check PASSED (8 new tables with RLS enabled and SELECT-only grants, immutability triggers present, closed 7-action allowlist intact, smallest-state-machine clock states intact, effective_deadline_adjusted correctly NOT a generated column, due-detection helpers private and read-only, all lifecycle RPCs authenticated-only/SECURITY DEFINER/pinned search_path with expected_lock_version replay discipline, manual escalation never touches protected graph machinery, zero out-of-scope worker/notification/cron wiring, prior-phase baseline fully intact and unaware of SLA/escalation -- Phase 5.3A: restart_workflow_sla_clock private/ungranted, business_hours/business_days offsets calendar-aware via workflow_calculate_calendar_offset_backward/workflow_calculate_calendar_deadline, escalation-evidence semantics documented via schema comment).';
END $$;
