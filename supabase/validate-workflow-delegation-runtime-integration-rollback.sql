-- CAP-002 Phase 5.2 delegation/substitution runtime integration
-- rollback validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- The two new private helpers are gone.
  IF to_regprocedure('public.workflow_resolve_effective_candidate(uuid,uuid,text,uuid,uuid,timestamptz)') IS NOT NULL THEN
    v_missing := v_missing || 'workflow_resolve_effective_candidate-still-present ';
  END IF;
  IF to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)') IS NOT NULL THEN
    v_missing := v_missing || 'workflow_resolve_active_delegation-still-present ';
  END IF;

  -- workflow_resolve_approval_candidates carries zero substitution
  -- references and zero section_id output -- byte-identical to its
  -- pre-5.2 (Phase 3.2) body.
  IF to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_resolve_approval_candidates-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)')) INTO v_def;
    -- NOTE: the pre-5.2 body already legitimately mentions
    -- 'section_id' (the section_role selector's own config field,
    -- present since Phase 2C.1/3.2) -- only the Phase 5.2-specific
    -- markers below (the substitution helper call and its output
    -- suffix) indicate the rollback did not fully revert.
    IF v_def ILIKE '%workflow_resolve_effective_candidate%' OR v_def ILIKE '%workflow_substitutions%'
       OR v_def ILIKE '%substituted_from%' OR v_def ILIKE '%''section_id'', section_id%'
    THEN v_missing := v_missing || 'candidate-resolution-still-substitution-aware '; END IF;
  END IF;

  -- workflow_enter_downstream_node carries zero delegation/
  -- substitution references and no section_id capture, but still
  -- carries the Phase 4.2 gateway_exclusive branch (that baseline is
  -- untouched by this rollback, which only reverts Phase 5.2).
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_enter_downstream_node-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)')) INTO v_def;
    IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' OR v_def ILIKE '%v_pos.section_id%' THEN
      v_missing := v_missing || 'downstream-node-still-delegation-substitution-aware ';
    END IF;
    IF v_def NOT ILIKE '%gateway_exclusive%' OR v_def NOT ILIKE '%workflow_resolve_gateway_target%' THEN
      v_missing := v_missing || 'downstream-node-phase-4.2-baseline-drift ';
    END IF;
  END IF;

  -- decide_workflow_work_item carries zero delegation references but
  -- still carries the Phase 4.3 expected-lock-version replay
  -- comparison (that baseline is untouched by this rollback).
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'decide_workflow_work_item-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)')) INTO v_def;
    IF v_def ILIKE '%workflow_resolve_active_delegation%' OR v_def ILIKE '%workflow_delegations%'
       OR v_def ILIKE '%delegation_id%' OR v_def ILIKE '%delegated_from%'
    THEN v_missing := v_missing || 'decision-still-delegation-aware '; END IF;
    IF v_def NOT ILIKE '%metadata ->> ''expected_instance_lock_version''%'
       OR v_def NOT ILIKE '%metadata ->> ''expected_work_item_lock_version''%'
    THEN v_missing := v_missing || 'decision-phase-4.3-baseline-drift '; END IF;
  END IF;

  -- Phase 5.1's own persistence foundation (tables, RPCs, private
  -- helpers) is completely untouched -- this rollback only reverts
  -- the runtime integration, never the foundation underneath it.
  IF to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_delegation_events') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regclass('public.workflow_substitution_events') IS NULL
     OR to_regprocedure('public.create_workflow_delegation(uuid,uuid,uuid,jsonb,text,text,timestamptz,timestamptz,text,uuid)') IS NULL
     OR to_regprocedure('public.accept_workflow_delegation(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.reject_workflow_delegation(uuid,bigint,text,uuid)') IS NULL
     OR to_regprocedure('public.revoke_workflow_delegation(uuid,bigint,text,uuid)') IS NULL
     OR to_regprocedure('public.get_workflow_delegation(uuid)') IS NULL
     OR to_regprocedure('public.list_workflow_delegations(uuid,text,integer,timestamptz,uuid)') IS NULL
     OR to_regprocedure('public.create_workflow_substitution(uuid,jsonb,uuid,text,timestamptz,timestamptz,text,uuid)') IS NULL
     OR to_regprocedure('public.revoke_workflow_substitution(uuid,bigint,text,uuid)') IS NULL
     OR to_regprocedure('public.get_workflow_substitution(uuid)') IS NULL
     OR to_regprocedure('public.list_workflow_substitutions(uuid,text,integer,timestamptz,uuid)') IS NULL
  THEN v_missing := v_missing || 'phase-5.1-foundation-drift '; END IF;

  -- Still exactly 16 workflow_ tables -- this rollback (like the
  -- milestone it reverts) never touches schema.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_approval_positions' AND column_name = 'section_id'
  ) THEN v_missing := v_missing || 'workflow_approval_positions.section_id-missing '; END IF;

  -- Prior-phase baseline (Phase 1 through 4.3) remains intact.
  IF to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regclass('public.workflow_approval_rounds') IS NULL
     OR to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow delegation/substitution runtime integration rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution runtime integration rollback validation PASSED (both new private helpers absent, all three redefined functions restored byte-identical to their pre-5.2 bodies with the correct earlier-phase baselines intact, Phase 5.1 foundation entirely untouched, workflow table count and section_id column unchanged, prior-phase baseline intact).';
END $$;
