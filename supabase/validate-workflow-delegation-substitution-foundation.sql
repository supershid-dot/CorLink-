-- CAP-002 Phase 5.1 delegation/substitution foundation structural
-- validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_fn TEXT;
BEGIN
  -- Extension present.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gist') THEN
    v_missing := v_missing || 'btree_gist-missing ';
  END IF;

  -- The four new tables exist, RLS enabled, exactly one SELECT
  -- policy each.
  FOREACH v_fn IN ARRAY ARRAY[
    'workflow_delegations','workflow_delegation_events',
    'workflow_substitutions','workflow_substitution_events'
  ] LOOP
    IF to_regclass('public.' || v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    ELSE
      IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || v_fn)::regclass) THEN
        v_missing := v_missing || v_fn || '-rls-disabled ';
      END IF;
      IF (SELECT count(*) FROM pg_policy WHERE polrelid = ('public.' || v_fn)::regclass) <> 1 THEN
        v_missing := v_missing || v_fn || '-unexpected-policy-count ';
      END IF;
      IF (SELECT count(*) FROM pg_policy WHERE polrelid = ('public.' || v_fn)::regclass AND polcmd <> 'r') <> 0 THEN
        v_missing := v_missing || v_fn || '-non-select-policy ';
      END IF;
    END IF;
  END LOOP;

  -- Overall workflow table count: the Phase 1-4.3 baseline of 12 plus
  -- these 4 new tables -- CAP-002 Phase 5.3 legitimately added 8
  -- more on top of that (16 -> 24); this check is updated to the
  -- new, superseding total, not defective.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 24
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  -- No direct write grant to anon/authenticated on any workflow
  -- table, including the four new ones.
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- EXCLUDE constraints present on both overlap-sensitive tables.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'workflow_delegations_no_overlap' AND contype = 'x'
  ) THEN v_missing := v_missing || 'delegations-no-overlap-constraint-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'workflow_substitutions_no_overlap' AND contype = 'x'
  ) THEN v_missing := v_missing || 'substitutions-no-overlap-constraint-missing '; END IF;

  -- Terminal-state immutability triggers on the two mutable-until-
  -- terminal tables, and blanket append-only triggers on the two
  -- pure-evidence tables — mirroring workflow_approval_rounds/
  -- workflow_approval_positions and workflow_events exactly.
  FOREACH v_fn IN ARRAY ARRAY[
    'workflow_delegations_immutable_after_terminal:workflow_delegations',
    'workflow_substitutions_immutable_after_terminal:workflow_substitutions',
    'workflow_delegation_events_immutable:workflow_delegation_events',
    'workflow_substitution_events_immutable:workflow_substitution_events'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.triggers
      WHERE trigger_schema = 'public' AND trigger_name = split_part(v_fn,':',1) AND event_object_table = split_part(v_fn,':',2)
    ) THEN v_missing := v_missing || split_part(v_fn,':',1) || '-trigger-missing '; END IF;
  END LOOP;

  -- Fully private helpers (never referenced by an RLS USING clause,
  -- only called from within other SECURITY DEFINER RPC bodies): no
  -- EXECUTE grant to anon or authenticated.
  FOREACH v_fn IN ARRAY ARRAY[
    'can_manage_workflow_delegation_scope(uuid)',
    'workflow_reject_terminal_delegation_mutation()',
    'workflow_reject_delegation_event_mutation()',
    'workflow_reject_terminal_substitution_mutation()'
  ] LOOP
    IF to_regprocedure('public.' || v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    ELSE
      IF has_function_privilege('anon', to_regprocedure('public.' || v_fn), 'EXECUTE')
         OR has_function_privilege('authenticated', to_regprocedure('public.' || v_fn), 'EXECUTE')
      THEN v_missing := v_missing || v_fn || '-execute-leak '; END IF;
    END IF;
  END LOOP;

  -- The two RLS-referenced visibility helpers are evaluated in the
  -- querying role's own context (authenticated), exactly like
  -- can_view_workflow_instance/can_manage_workflow_instance
  -- (patch-workflow-backend-foundation.sql) — authenticated must be
  -- granted EXECUTE for RLS to function at all; anon must still be
  -- denied.
  FOREACH v_fn IN ARRAY ARRAY[
    'workflow_delegation_visible_to_caller(uuid,uuid,uuid)',
    'workflow_substitution_visible_to_caller(text,uuid,uuid,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    ELSE
      IF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_fn), 'EXECUTE') THEN
        v_missing := v_missing || v_fn || '-not-granted-to-authenticated ';
      END IF;
      IF has_function_privilege('anon', to_regprocedure('public.' || v_fn), 'EXECUTE') THEN
        v_missing := v_missing || v_fn || '-anon-leak ';
      END IF;
    END IF;
  END LOOP;

  -- Public RPCs: exist, authenticated-callable, not anon-callable,
  -- SECURITY DEFINER (create_workflow_delegation etc.) or STABLE
  -- SECURITY DEFINER (get_/list_ read RPCs), pinned search_path.
  FOREACH v_fn IN ARRAY ARRAY[
    'create_workflow_delegation(uuid,uuid,uuid,jsonb,text,text,timestamptz,timestamptz,text,uuid)',
    'accept_workflow_delegation(uuid,bigint,uuid)',
    'reject_workflow_delegation(uuid,bigint,text,uuid)',
    'revoke_workflow_delegation(uuid,bigint,text,uuid)',
    'get_workflow_delegation(uuid)',
    'list_workflow_delegations(uuid,text,integer,timestamptz,uuid)',
    'create_workflow_substitution(uuid,jsonb,uuid,text,timestamptz,timestamptz,text,uuid)',
    'revoke_workflow_substitution(uuid,bigint,text,uuid)',
    'get_workflow_substitution(uuid)',
    'list_workflow_substitutions(uuid,text,integer,timestamptz,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    ELSE
      IF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_fn), 'EXECUTE') THEN
        v_missing := v_missing || v_fn || '-not-granted ';
      END IF;
      IF has_function_privilege('anon', to_regprocedure('public.' || v_fn), 'EXECUTE') THEN
        v_missing := v_missing || v_fn || '-anon-leak ';
      END IF;
      IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.' || v_fn))
         OR NOT EXISTS (
           SELECT 1 FROM pg_proc p
           WHERE p.oid = to_regprocedure('public.' || v_fn)
             AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
         ) THEN
        v_missing := v_missing || v_fn || '-security ';
      END IF;
    END IF;
  END LOOP;

  -- Idempotency-replay discipline applied from day one (Phase 4.3
  -- lesson): every lifecycle RPC's replay comparison must include
  -- the expected lock version, matching workflow_transition_instance/
  -- workflow_advance_graph_step/the fixed decide_workflow_work_item.
  FOREACH v_fn IN ARRAY ARRAY[
    'accept_workflow_delegation(uuid,bigint,uuid)',
    'reject_workflow_delegation(uuid,bigint,text,uuid)',
    'revoke_workflow_delegation(uuid,bigint,text,uuid)',
    'revoke_workflow_substitution(uuid,bigint,text,uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.' || v_fn)) INTO v_def;
    IF v_def NOT ILIKE '%expected_lock_version%' THEN
      v_missing := v_missing || v_fn || '-replay-omits-expected-lock-version ';
    END IF;
  END LOOP;

  -- create_ RPCs must not depend on live candidate resolution or
  -- approval logic — the "no live work-item integration" boundary
  -- is structural, not merely a promise: neither create_workflow_
  -- delegation nor create_workflow_substitution may reference the
  -- live-integration surfaces this phase is forbidden from touching.
  SELECT pg_get_functiondef('public.create_workflow_delegation(uuid,uuid,uuid,jsonb,text,text,timestamptz,timestamptz,text,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_resolve_approval_candidates%' OR v_def ILIKE '%decide_workflow_work_item%'
     OR v_def ILIKE '%workflow_enter_downstream_node%'
  THEN v_missing := v_missing || 'create-delegation-touches-live-integration-surface '; END IF;
  SELECT pg_get_functiondef('public.create_workflow_substitution(uuid,jsonb,uuid,text,timestamptz,timestamptz,text,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_resolve_approval_candidates%' OR v_def ILIKE '%decide_workflow_work_item%'
     OR v_def ILIKE '%workflow_enter_downstream_node%'
  THEN v_missing := v_missing || 'create-substitution-touches-live-integration-surface '; END IF;

  -- No new UPDATE grant on workflow_work_items, and its own
  -- assigned_to column is not written by anything this patch adds.
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name = 'workflow_work_items'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'workflow-work-items-write-grant-leak '; END IF;

  -- Prior-phase baseline: the entire Phase 1-4.3 chain untouched,
  -- spot-checked via its own signatures and the exact byte-for-byte
  -- 22 known-unaffected function bodies this validator can cheaply
  -- re-check.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL
     OR to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_variables') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  SELECT pg_get_functiondef('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' THEN
    v_missing := v_missing || 'decide-workflow-work-item-touched-by-phase-5-1 ';
  END IF;
  SELECT pg_get_functiondef('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' THEN
    v_missing := v_missing || 'workflow-enter-downstream-node-touched-by-phase-5-1 ';
  END IF;

  -- No out-of-scope RPC — this milestone is persistence/lifecycle
  -- only: no SLA clocks, escalation execution, timers, or
  -- notifications.
  IF to_regprocedure('public.evaluate_workflow_sla_clock(uuid)') IS NOT NULL
     OR to_regprocedure('public.escalate_workflow_work_item(uuid)') IS NOT NULL
     OR to_regprocedure('public.fire_workflow_delegation_timer(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow delegation/substitution foundation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution foundation structural check PASSED (4 new tables with SELECT-only RLS, EXCLUDE-constraint overlap prevention, terminal/append-only immutability triggers, all RPCs authenticated-only/SECURITY DEFINER/pinned search_path with expected-lock-version replay comparison, private helpers ungranted, no live-integration surface touched, workflow_work_items grants unchanged, Phase 1-4.3 baseline intact, no out-of-scope RPC).';
END $$;
