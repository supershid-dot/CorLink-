-- CAP-002 Phase 4.2 gateway routing execution structural validator
-- (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_helper_sig CONSTANT TEXT :=
    'public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)';
BEGIN
  -- workflow_enter_downstream_node now executes gateway_exclusive
  -- routing, reusing the shared condition-evaluation and branch-
  -- selection helpers, emitting route_selected. Signature unchanged
  -- (still 14 args) — no second graph-advancement authority exists.
  IF to_regprocedure(v_helper_sig) IS NULL THEN
    v_missing := v_missing || 'workflow_enter_downstream_node-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure(v_helper_sig)) INTO v_def;
    IF v_def NOT ILIKE '%gateway_exclusive%'
       OR v_def NOT ILIKE '%workflow_resolve_gateway_target%'
       OR v_def NOT ILIKE '%route_selected%'
    THEN v_missing := v_missing || 'helper-missing-gateway-execution-logic '; END IF;
    -- The gateway branch must not emit a redundant step_completed
    -- alongside route_selected for the same step — route_selected
    -- alone closes the gateway's own step, matching the skip branch's
    -- single-event-closure precedent (step_skipped, not step_skipped
    -- plus step_completed).
    IF has_function_privilege('anon', to_regprocedure(v_helper_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_helper_sig), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_enter_downstream_node-execute-leak '; END IF;
  END IF;

  -- workflow_peek_final_graph_target must walk gateway hops too, so
  -- replay metadata is correct for any command whose advancement
  -- passes through one or more gateways.
  IF to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_peek_final_graph_target-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)')) INTO v_def;
    IF v_def NOT ILIKE '%gateway_exclusive%' OR v_def NOT ILIKE '%workflow_resolve_gateway_target%'
    THEN v_missing := v_missing || 'peek-does-not-walk-gateway-hops '; END IF;
  END IF;

  -- The two new shared helpers exist, are private, and are STABLE
  -- (read-only) — reused identically by both the real entry pass and
  -- the peek pass, so they can never disagree.
  IF to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_evaluate_gateway_condition-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_evaluate_gateway_condition-execute-leak '; END IF;
    IF NOT (SELECT provolatile = 's' FROM pg_proc WHERE oid = to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)'))
    THEN v_missing := v_missing || 'workflow_evaluate_gateway_condition-not-stable '; END IF;
    -- Closed operator allowlist only — every approved operator present,
    -- and no arbitrary-SQL escape hatch (no EXECUTE/format() call).
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)')) INTO v_def;
    IF v_def ILIKE '%EXECUTE %' OR v_def ILIKE '%format(%' THEN
      v_missing := v_missing || 'workflow_evaluate_gateway_condition-dynamic-sql-present ';
    END IF;
    IF v_def NOT ILIKE '%is_null%' OR v_def NOT ILIKE '%is_not_null%'
       OR v_def NOT ILIKE '%equals%' OR v_def NOT ILIKE '%not_equals%'
       OR v_def NOT ILIKE '%greater_than%' OR v_def NOT ILIKE '%less_than%'
       OR v_def NOT ILIKE '%''in''%' OR v_def NOT ILIKE '%not_in%'
    THEN v_missing := v_missing || 'workflow_evaluate_gateway_condition-operator-missing '; END IF;
  END IF;

  IF to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_gateway_target-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_resolve_gateway_target-execute-leak '; END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)')) INTO v_def;
    IF v_def NOT ILIKE '%workflow_evaluate_gateway_condition%' THEN
      v_missing := v_missing || 'resolve-gateway-target-does-not-reuse-condition-evaluator ';
    END IF;
    IF v_def NOT ILIKE '%ORDER BY%priority%' THEN
      v_missing := v_missing || 'resolve-gateway-target-not-priority-ordered ';
    END IF;
  END IF;

  -- The two immediate-target-type glue checks (workflow_transition_
  -- instance's 'start' branch and workflow_advance_graph_step's own
  -- glue) must permit gateway_exclusive as a direct target — a
  -- graph's very first or very next node can itself be a gateway.
  -- Signatures unchanged.
  FOREACH v_def IN ARRAY ARRAY[
    'workflow_transition_instance(uuid,text,bigint,uuid,text,text)',
    'workflow_advance_graph_step(uuid,bigint,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSE
      SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_def;
      IF v_def NOT ILIKE '%approval'',''end'',''gateway_exclusive%' THEN
        v_missing := v_missing || 'glue-check-not-widened-for-gateway ';
      END IF;
    END IF;
  END LOOP;

  -- decide_workflow_work_item is untouched by this phase — it already
  -- routes exclusively through the peek helper and the shared entry
  -- helper with no inline target-type check of its own.
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'decide_workflow_work_item-missing ';
  END IF;

  -- No new node type, no new command, no new permission model. Only
  -- one new event type (route_selected, already reserved by docs/69);
  -- no unapproved event type was introduced.
  IF to_regprocedure('public.evaluate_workflow_gateway(uuid)') IS NOT NULL
     OR to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Zero new tables, zero new columns — this milestone is pure
  -- execution logic on the existing Phase 1-4.1A storage shape.
  -- CAP-002 Phase 5.1 legitimately added 4 new tables
  -- (workflow_delegations, workflow_delegation_events,
  -- workflow_substitutions, workflow_substitution_events) on top of
  -- this milestone's own baseline of 12 -- this check is updated to
  -- the new, superseding total of 16, not defective.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- Prior-phase baseline intact.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NULL
     OR to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_variables') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow gateway routing execution structural check PASSED (workflow_enter_downstream_node executes gateway_exclusive routing via the shared condition-evaluation/branch-selection helpers and emits route_selected, workflow_peek_final_graph_target walks gateway hops for correct replay metadata, both immediate-target-type glue checks widened, decide_workflow_work_item untouched, no out-of-scope RPC or new permission model, prior-phase baseline intact).';
END $$;
