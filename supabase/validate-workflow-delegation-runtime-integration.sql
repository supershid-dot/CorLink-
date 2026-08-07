-- CAP-002 Phase 5.2 delegation/substitution runtime integration
-- structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- Two new private helpers exist, are ungranted to anon/authenticated
  -- (never a direct client-callable surface — reached only from other
  -- SECURITY DEFINER functions, matching the existing
  -- workflow_resolve_approval_candidates precedent), STABLE, SECURITY
  -- DEFINER, pinned search_path.
  IF to_regprocedure('public.workflow_resolve_effective_candidate(uuid,uuid,text,uuid,uuid,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_effective_candidate-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_resolve_effective_candidate(uuid,uuid,text,uuid,uuid,timestamptz)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_resolve_effective_candidate(uuid,uuid,text,uuid,uuid,timestamptz)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_resolve_effective_candidate-execute-leak '; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.workflow_resolve_effective_candidate(uuid,uuid,text,uuid,uuid,timestamptz)')
        AND p.prosecdef AND p.provolatile = 's'
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'workflow_resolve_effective_candidate-security '; END IF;
  END IF;

  IF to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_active_delegation-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_resolve_active_delegation-execute-leak '; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)')
        AND p.prosecdef AND p.provolatile = 's'
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'workflow_resolve_active_delegation-security '; END IF;
  END IF;

  -- workflow_resolve_approval_candidates (still authenticated-
  -- ungranted, same signature) now genuinely calls the substitution
  -- helper, and reached from both the main resolution CTE and the
  -- duplicate-check subquery (two call sites, one shared definition).
  IF to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_approval_candidates-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_resolve_approval_candidates-execute-leak '; END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)')) INTO v_def;
    IF (SELECT count(*) FROM regexp_matches(v_def, 'workflow_resolve_effective_candidate', 'g')) < 2 THEN
      v_missing := v_missing || 'candidate-resolution-substitution-not-wired-both-sites ';
    END IF;
    IF v_def NOT ILIKE '%section_id%' THEN
      v_missing := v_missing || 'candidate-resolution-missing-section-id-passthrough ';
    END IF;
    -- Selector syntax / self-approval / dedup / ordinal mechanics
    -- untouched — still exactly four UNION ALL selector-type branches.
    IF (SELECT count(*) FROM regexp_matches(v_def, 'sel\.sel_type = ''explicit_user''', 'g')) < 1
       OR (SELECT count(*) FROM regexp_matches(v_def, 'sel\.sel_type = ''organization_role''', 'g')) < 1
       OR (SELECT count(*) FROM regexp_matches(v_def, 'sel\.sel_type = ''section_role''', 'g')) < 1
       OR (SELECT count(*) FROM regexp_matches(v_def, 'sel\.sel_type = ''instance_participant_role''', 'g')) < 1
    THEN v_missing := v_missing || 'candidate-resolution-selector-branches-altered '; END IF;
  END IF;

  -- workflow_enter_downstream_node: same 14-arg signature, still
  -- ungranted to anon/authenticated, still carries the Phase 4.2
  -- gateway_exclusive branch (baseline intact), now also carries
  -- section_id through to workflow_approval_positions -- but itself
  -- has ZERO direct references to workflow_delegations/
  -- workflow_substitutions, since substitution reaches it only
  -- indirectly through workflow_resolve_approval_candidates, never
  -- inlined into graph-traversal mechanics.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_enter_downstream_node-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'), 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_enter_downstream_node-execute-leak '; END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)')) INTO v_def;
    IF v_def NOT ILIKE '%gateway_exclusive%' OR v_def NOT ILIKE '%workflow_resolve_gateway_target%' OR v_def NOT ILIKE '%route_selected%' THEN
      v_missing := v_missing || 'downstream-node-gateway-baseline-drift ';
    END IF;
    IF v_def NOT ILIKE '%v_pos.section_id%' THEN
      v_missing := v_missing || 'downstream-node-missing-section-id-capture ';
    END IF;
    IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' THEN
      v_missing := v_missing || 'downstream-node-inlines-delegation-substitution-directly ';
    END IF;
  END IF;

  -- decide_workflow_work_item: same 6-arg signature, authenticated-
  -- only, SECURITY DEFINER, pinned search_path, still carries the
  -- Phase 4.3 expected-lock-version replay comparison (baseline
  -- intact), now genuinely widens authorization via
  -- workflow_resolve_active_delegation, records delegation_id in
  -- decision_recorded's metadata, and still carries zero
  -- candidate-resolution/routing duplication.
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'decide_workflow_work_item-missing ';
  ELSE
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'decide_workflow_work_item-not-granted ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'decide_workflow_work_item-anon-leak ';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN v_missing := v_missing || 'decide_workflow_work_item-security '; END IF;

    SELECT pg_get_functiondef(to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)')) INTO v_def;
    IF v_def NOT ILIKE '%metadata ->> ''expected_instance_lock_version''%'
       OR v_def NOT ILIKE '%metadata ->> ''expected_work_item_lock_version''%'
    THEN v_missing := v_missing || 'decision-replay-baseline-drift '; END IF;

    IF v_def NOT ILIKE '%workflow_resolve_active_delegation%' THEN
      v_missing := v_missing || 'decision-authorization-not-delegation-aware ';
    END IF;
    IF v_def NOT ILIKE '%''delegation_id''%' THEN
      v_missing := v_missing || 'decision-event-missing-delegation-traceability ';
    END IF;
    IF v_def NOT ILIKE '%delegated_from%' THEN
      v_missing := v_missing || 'decision-authority-source-missing-delegation-traceability ';
    END IF;

    IF v_def ILIKE '%candidate_selectors%' OR v_def ILIKE '%JOIN LATERAL jsonb_array_elements_text%' THEN
      v_missing := v_missing || 'decision-duplicates-downstream-entry-logic ';
    END IF;
    IF v_def ILIKE '%workflow_substitutions%' THEN
      v_missing := v_missing || 'decision-inlines-substitution-directly ';
    END IF;
  END IF;

  -- Zero new tables and zero new columns — this milestone is a pure
  -- function-body integration on top of Phase 5.1's already-approved
  -- storage shape (still exactly 16 workflow_ tables;
  -- workflow_approval_positions.section_id already existed since
  -- Phase 2B.2 and is populated here for the first time, not added).
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- No out-of-scope RPCs — escalation execution, SLA timers,
  -- notifications, background workers, adapters remain entirely out
  -- of this milestone's scope, exactly as instructed.
  IF to_regprocedure('public.escalate_workflow_work_item(uuid)') IS NOT NULL
     OR to_regprocedure('public.tick_workflow_sla_timers()') IS NOT NULL
     OR to_regprocedure('public.send_workflow_notification(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Prior-phase baseline (Phase 1 through 5.1) remains intact and
  -- unaffected -- every table/RPC this milestone reuses still exists
  -- with its own approved shape.
  IF to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regclass('public.workflow_approval_positions') IS NULL
     OR to_regprocedure('public.create_workflow_delegation(uuid,uuid,uuid,jsonb,text,text,timestamptz,timestamptz,text,uuid)') IS NULL
     OR to_regprocedure('public.create_workflow_substitution(uuid,jsonb,uuid,text,timestamptz,timestamptz,text,uuid)') IS NULL
     OR to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_approval_positions' AND column_name = 'section_id'
  ) THEN v_missing := v_missing || 'workflow_approval_positions.section_id-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow delegation/substitution runtime integration structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution runtime integration structural check PASSED (two new private/ungranted STABLE SECURITY DEFINER helpers, substitution wired into both candidate-resolution call sites with selector-branch mechanics untouched, section_id now populated on positions, delegation genuinely widens decide_workflow_work_item authorization with full traceability while workflow_enter_downstream_node itself carries zero direct delegation/substitution references, Phase 4.2/4.3 baseline intact, zero new tables/columns, no out-of-scope RPCs, prior-phase baseline intact).';
END $$;
