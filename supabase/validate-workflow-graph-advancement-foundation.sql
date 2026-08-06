-- CAP-002 Phase 2C.1 graph advancement foundation structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- The shared downstream-node-entry helper exists, is SECURITY
  -- DEFINER with a pinned search_path, and is never directly callable
  -- by any client role — reachable only from within another
  -- SECURITY DEFINER function's already-authorized transaction.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL THEN
    v_missing := v_missing || 'workflow_enter_downstream_node-missing ';
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid = to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN
      v_missing := v_missing || 'workflow_enter_downstream_node-security ';
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'workflow_enter_downstream_node'
        AND (
          has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
        )
    ) THEN v_missing := v_missing || 'workflow_enter_downstream_node-execute-leak '; END IF;
  END IF;

  -- workflow_advance_graph_step exists, is authenticated-callable
  -- (not anon), SECURITY DEFINER, pinned search_path.
  IF to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NULL THEN
    v_missing := v_missing || 'workflow_advance_graph_step-missing ';
  ELSE
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'workflow_advance_graph_step-not-granted ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'workflow_advance_graph_step-anon-leak ';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid = to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN
      v_missing := v_missing || 'workflow_advance_graph_step-security ';
    END IF;
  END IF;

  -- workflow_advance_graph_step reuses existing authorization, not a
  -- duplicated model.
  SELECT pg_get_functiondef('workflow_advance_graph_step(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%can_manage_workflow_instance%'
     OR v_def NOT ILIKE '%workflow_actor_is_active%'
     OR v_def NOT ILIKE '%workflow_enter_downstream_node%'
     OR v_def NOT ILIKE '%schema_version%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
  THEN v_missing := v_missing || 'advance-logic-markers '; END IF;

  -- workflow_transition_instance retains its exact signature and
  -- grant posture (revoked from PUBLIC/anon/authenticated, reachable
  -- only via the 5 wrapper RPCs), and now calls the shared helper
  -- instead of carrying its own duplicate inline End/Approval entry
  -- logic (a true extraction, not a second copy).
  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_transition_instance-missing ';
  ELSIF has_function_privilege('authenticated', to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)'), 'EXECUTE')
     OR has_function_privilege('anon', to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)'), 'EXECUTE') THEN
    v_missing := v_missing || 'workflow_transition_instance-execute-leak ';
  END IF;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%workflow_enter_downstream_node%'
  THEN v_missing := v_missing || 'activation-does-not-call-shared-helper '; END IF;
  IF v_def ILIKE '%candidate_selectors%'
     OR v_def ILIKE '%JOIN LATERAL jsonb_array_elements_text%'
     OR v_def ILIKE '%workflow_approval_rounds (%'
  THEN v_missing := v_missing || 'activation-still-carries-duplicated-approval-logic '; END IF;

  -- The 5 public wrapper RPCs are unaffected.
  FOREACH v_def IN ARRAY ARRAY[
    'start_workflow_instance(uuid,bigint,uuid)',
    'suspend_workflow_instance(uuid,bigint,uuid,text)',
    'resume_workflow_instance(uuid,bigint,uuid,text)',
    'cancel_workflow_instance(uuid,bigint,uuid,text)',
    'complete_workflow_instance(uuid,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSIF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || v_def || '-not-granted ';
    ELSIF has_function_privilege('anon', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || v_def || '-anon-leak ';
    END IF;
  END LOOP;

  -- No out-of-scope RPCs were added — this milestone is generic
  -- advancement only, no decision recording, no routing.
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text)') IS NOT NULL
     OR to_regprocedure('public.record_workflow_decision(uuid,text)') IS NOT NULL
     OR to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Zero new tables — this milestone reuses Phase 2B.2's storage
  -- shape unchanged; still exactly the Phase 1+2B.2 baseline of 12.
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

  -- Phase 2B.1 canonicalizer and Phase 2B.2 activation logic remain intact.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'canonicalizer-missing ';
  END IF;
  IF to_regclass('workflow_approval_rounds') IS NULL OR to_regclass('workflow_approval_positions') IS NULL THEN
    v_missing := v_missing || 'phase-2b2-tables-missing ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow graph advancement foundation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow graph advancement foundation structural check PASSED (shared downstream-entry helper private and pinned, workflow_advance_graph_step authenticated-only and reusing existing authorization, activation now calls the shared helper with no duplicated logic remaining, wrapper RPCs and Phase 1/2/2B.1/2B.2 baseline intact, no out-of-scope RPCs).';
END $$;
