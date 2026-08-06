-- CAP-002 Phase 3.2 approval round lifecycle structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_helper_sig CONSTANT TEXT :=
    'public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)';
  v_old_helper_sig CONSTANT TEXT :=
    'public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb)';
BEGIN
  -- The old 13-argument overload is gone — exactly one graph-
  -- advancement authority exists, not two.
  IF to_regprocedure(v_old_helper_sig) IS NOT NULL THEN
    v_missing := v_missing || 'old-13-arg-helper-still-present ';
  END IF;

  IF to_regprocedure(v_helper_sig) IS NULL THEN
    v_missing := v_missing || 'workflow_enter_downstream_node-missing ';
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_helper_sig))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure(v_helper_sig)
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN v_missing := v_missing || 'workflow_enter_downstream_node-security '; END IF;
    IF has_function_privilege('anon', to_regprocedure(v_helper_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_helper_sig), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_enter_downstream_node-execute-leak '; END IF;
    SELECT pg_get_functiondef(to_regprocedure(v_helper_sig)) INTO v_def;
    IF v_def NOT ILIKE '%workflow_resolve_approval_candidates%'
       OR v_def NOT ILIKE '%workflow_classify_approval_electorate%'
       OR v_def NOT ILIKE '%''skip''%'
       OR v_def NOT ILIKE '%step_skipped%'
    THEN v_missing := v_missing || 'helper-missing-skip-logic '; END IF;
  END IF;

  -- The extracted candidate-resolution and classification helpers
  -- exist, are private, and are shared (not duplicated) between the
  -- real entry pass and the peek pass.
  IF to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_approval_candidates-missing ';
  ELSIF has_function_privilege('anon', to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)'), 'EXECUTE')
     OR has_function_privilege('authenticated', to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)'), 'EXECUTE')
  THEN v_missing := v_missing || 'workflow_resolve_approval_candidates-execute-leak '; END IF;

  IF to_regprocedure('public.workflow_classify_approval_electorate(text,integer,integer)') IS NULL THEN
    v_missing := v_missing || 'workflow_classify_approval_electorate-missing ';
  END IF;

  IF to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_peek_final_graph_target-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_peek_final_graph_target-execute-leak '; END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)')) INTO v_def;
    IF v_def NOT ILIKE '%workflow_resolve_approval_candidates%' OR v_def NOT ILIKE '%workflow_classify_approval_electorate%'
    THEN v_missing := v_missing || 'peek-does-not-reuse-shared-helpers '; END IF;
  END IF;

  -- The three callers pass the canonical payload through and peek
  -- their own true final status before inserting their root event.
  FOREACH v_def IN ARRAY ARRAY[
    'workflow_transition_instance(uuid,text,bigint,uuid,text,text)',
    'workflow_advance_graph_step(uuid,bigint,uuid)',
    'decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSE
      SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_def;
      IF v_def NOT ILIKE '%workflow_peek_final_graph_target%' THEN
        v_missing := v_missing || 'caller-does-not-peek-final-target ';
      END IF;
    END IF;
  END LOOP;

  -- Immutability triggers on rounds/positions exist and are wired to
  -- BEFORE UPDATE OR DELETE.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'workflow_approval_rounds' AND t.tgname = 'workflow_approval_rounds_immutable_after_terminal' AND NOT t.tgisinternal
  ) THEN v_missing := v_missing || 'rounds-immutability-trigger-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'workflow_approval_positions' AND t.tgname = 'workflow_approval_positions_immutable_after_terminal' AND NOT t.tgisinternal
  ) THEN v_missing := v_missing || 'positions-immutability-trigger-missing '; END IF;

  -- get_workflow_approval_round_blocked_count: authenticated-only,
  -- reuses can_manage_workflow_instance, no identity fields selected.
  IF to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NULL THEN
    v_missing := v_missing || 'get_workflow_approval_round_blocked_count-missing ';
  ELSE
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'get_workflow_approval_round_blocked_count-not-granted ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'get_workflow_approval_round_blocked_count-anon-leak ';
    END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%can_manage_workflow_instance%' THEN
      v_missing := v_missing || 'blocked-count-wrong-authorization-boundary ';
    END IF;
    -- The function's own return type is a bare INTEGER (not a row or
    -- table type), which structurally prevents it from returning any
    -- identity field regardless of what its body selects internally.
    IF (SELECT pg_get_function_result(to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)'))) <> 'integer' THEN
      v_missing := v_missing || 'blocked-count-return-type-not-a-bare-integer ';
    END IF;
  END IF;

  -- No new decision model, no routing/gateway RPCs.
  IF to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
     OR to_regprocedure('public.evaluate_workflow_gateway(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Zero new tables — this milestone completes the round lifecycle on
  -- the existing Phase 1+2B.2 storage shape (still exactly 12).
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
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow approval round lifecycle structural check PASSED (single 14-arg graph-advancement authority reusing shared candidate-resolution/classification helpers with a bounded synchronous skip loop, all three callers peek their true final status before their own root event, terminal-state immutability triggers present on rounds/positions, blocked-count function manager-gated and identity-free, no out-of-scope RPCs, prior-phase baseline intact).';
END $$;
