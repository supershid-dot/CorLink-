-- CAP-002 Phase 3.1 approval decision engine structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_fn CONSTANT TEXT := 'public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)';
BEGIN
  -- decide_workflow_work_item exists, is authenticated-callable (not
  -- anon), SECURITY DEFINER, pinned search_path.
  IF to_regprocedure(v_fn) IS NULL THEN
    v_missing := v_missing || 'decide_workflow_work_item-missing ';
  ELSE
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_fn), 'EXECUTE') THEN
      v_missing := v_missing || 'decide_workflow_work_item-not-granted ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure(v_fn), 'EXECUTE') THEN
      v_missing := v_missing || 'decide_workflow_work_item-anon-leak ';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid = to_regprocedure(v_fn)
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN
      v_missing := v_missing || 'decide_workflow_work_item-security ';
    END IF;
  END IF;

  -- Reuses existing authorization/activity helpers and the shared
  -- graph-advancement helper — never a duplicated permission model or
  -- a second copy of downstream-entry mechanics. Assignment-based
  -- ownership check (work_item.assigned_to), not
  -- can_manage_workflow_instance (a deliberately different boundary
  -- from lifecycle commands, per docs/63).
  SELECT pg_get_functiondef(to_regprocedure(v_fn)) INTO v_def;
  IF v_def NOT ILIKE '%workflow_actor_is_active%'
     OR v_def NOT ILIKE '%workflow_enter_downstream_node%'
     OR v_def NOT ILIKE '%assigned_to%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
     OR v_def NOT ILIKE '%approval_threshold%'
  THEN v_missing := v_missing || 'decision-logic-markers '; END IF;

  -- Must not duplicate downstream-entry mechanics (candidate
  -- resolution / round-opening / atomic end-completion) — that
  -- remains centralized in workflow_enter_downstream_node.
  IF v_def ILIKE '%candidate_selectors%'
     OR v_def ILIKE '%JOIN LATERAL jsonb_array_elements_text%'
  THEN v_missing := v_missing || 'decision-duplicates-downstream-entry-logic '; END IF;

  -- Must not implement routing/gateway/conditional-branching concepts
  -- beyond the single outcome-matched edge lookup it re-derives (the
  -- same small glue query workflow_advance_graph_step already uses).
  IF v_def ILIKE '%gateway%' OR v_def ILIKE '%conditional_branch%' THEN
    v_missing := v_missing || 'decision-implements-out-of-scope-routing ';
  END IF;

  -- workflow_decisions gained round/position linkage with NOT NULL
  -- and database-enforced composite (id, instance_id) foreign keys —
  -- "private-function checks alone are insufficient" (docs/63).
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_decisions'
      AND column_name = 'round_id' AND is_nullable = 'NO'
  ) THEN v_missing := v_missing || 'workflow_decisions.round_id-missing-or-nullable '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_decisions'
      AND column_name = 'position_id' AND is_nullable = 'NO'
  ) THEN v_missing := v_missing || 'workflow_decisions.position_id-missing-or-nullable '; END IF;

  FOREACH v_def IN ARRAY ARRAY[
    'workflow_decisions_round_instance_fkey',
    'workflow_decisions_position_instance_fkey',
    'workflow_decisions_workitem_instance_fkey',
    'workflow_decisions_step_instance_fkey'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      WHERE t.relname = 'workflow_decisions' AND c.conname = v_def AND c.contype = 'f'
    ) THEN v_missing := v_missing || v_def || '-missing '; END IF;
  END LOOP;

  FOREACH v_def IN ARRAY ARRAY[
    'workflow_instance_steps_id_instance_unique',
    'workflow_approval_rounds_id_instance_unique',
    'workflow_approval_positions_id_instance_unique',
    'workflow_work_items_id_instance_unique'
  ] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = v_def AND contype = 'u') THEN
      v_missing := v_missing || v_def || '-missing ';
    END IF;
  END LOOP;

  -- No out-of-scope RPCs — this milestone is decision recording only,
  -- no routing/gateway/timer/notification/delegation commands.
  IF to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
     OR to_regprocedure('public.delegate_workflow_decision(uuid,uuid)') IS NOT NULL
     OR to_regprocedure('public.escalate_workflow_work_item(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Zero new tables — this milestone extends existing storage
  -- (workflow_decisions gains columns; four tables gain a unique
  -- constraint) rather than introducing new tables. Still exactly the
  -- Phase 1+2B.2 baseline of 12.
  -- CAP-002 Phase 5.1 legitimately added 4 new tables
  -- (workflow_delegations, workflow_delegation_events,
  -- workflow_substitutions, workflow_substitution_events) on top of
  -- this milestone's own baseline of 12 -- this check is updated to
  -- the new, superseding total of 16, not defective.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated')
      AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- CAP-002 Phase 4.3 stabilization fix: the idempotency-replay
  -- comparison must include both expected lock-version fields, not
  -- just work_item_id/decision_code/comment — matching docs/67's own
  -- "identical semantics to every other command" claim and mirroring
  -- workflow_transition_instance/workflow_advance_graph_step's own
  -- expected_lock_version comparison. Re-fetches the function body
  -- fresh (v_def is reused as a loop variable elsewhere in this file)
  -- and checks for the quoted metadata-key read, not the bare
  -- parameter name (which appears in both the pre- and post-fix
  -- bodies as an ordinary function argument).
  SELECT pg_get_functiondef(to_regprocedure(v_fn)) INTO v_def;
  IF v_def NOT ILIKE '%metadata ->> ''expected_instance_lock_version''%'
     OR v_def NOT ILIKE '%metadata ->> ''expected_work_item_lock_version''%'
  THEN v_missing := v_missing || 'decision-replay-omits-expected-lock-version-comparison '; END IF;

  -- Prior-phase baseline (2C.1 shared helper + graph-advancement
  -- command, 2B.1 canonicalizer, 2B.2 approval-round tables) remains
  -- intact and unaffected.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow approval decision engine structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow approval decision engine structural check PASSED (decide_workflow_work_item authenticated-only, SECURITY DEFINER, pinned search_path, reuses workflow_enter_downstream_node and assignment-based authorization with no duplicated downstream-entry or routing logic, workflow_decisions gained enforced round/position composite linkage, prior-phase baseline intact, no out-of-scope RPCs).';
END $$;
