-- CAP-002 Phase 4.2 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  -- The two wholly-new Phase 4.2 helpers must be gone entirely.
  IF to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_evaluate_gateway_condition still exists';
  END IF;
  IF to_regprocedure('public.workflow_resolve_gateway_target(uuid,jsonb,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_resolve_gateway_target still exists';
  END IF;

  -- The four restored functions must exist and carry zero
  -- gateway-execution logic — restored to their exact pre-4.2
  -- (Phase 4.1A) bodies, not merely functionally equivalent ones.
  IF to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_peek_final_graph_target is missing';
  END IF;
  SELECT pg_get_functiondef('workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' OR v_def ILIKE '%workflow_resolve_gateway_target%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_peek_final_graph_target still walks gateway hops';
  END IF;
  IF v_def NOT ILIKE '%NOT IN (''approval'',''end'')%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_peek_final_graph_target does not carry the exact pre-4.2 approval/end-only type check';
  END IF;

  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_enter_downstream_node is missing';
  END IF;
  SELECT pg_get_functiondef('workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' OR v_def ILIKE '%route_selected%' OR v_def ILIKE '%workflow_resolve_gateway_target%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_enter_downstream_node still carries gateway-execution logic';
  END IF;
  IF v_def NOT ILIKE '%NOT IN (''approval'',''end'')%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_enter_downstream_node does not carry the exact pre-4.2 approval/end-only type check';
  END IF;

  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_transition_instance is missing';
  END IF;
  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_transition_instance still widened for gateway_exclusive';
  END IF;
  IF v_def NOT ILIKE '%NOT IN (''approval'',''end'')%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_transition_instance does not carry the exact pre-4.2 approval/end-only type check';
  END IF;

  IF to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_advance_graph_step is missing';
  END IF;
  SELECT pg_get_functiondef('workflow_advance_graph_step(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_advance_graph_step still widened for gateway_exclusive';
  END IF;
  IF v_def NOT ILIKE '%NOT IN (''approval'',''end'')%' THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; workflow_advance_graph_step does not carry the exact pre-4.2 approval/end-only type check';
  END IF;

  -- decide_workflow_work_item was never touched by Phase 4.2 and must
  -- still be present, untouched, after rollback.
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; decide_workflow_work_item is missing';
  END IF;

  -- No route_selected event can exist post-rollback — the rollback
  -- itself refuses to run while any exist, and this milestone deletes
  -- no rows, so this is a pure sanity check on the invariant.
  IF EXISTS (SELECT 1 FROM workflow_events WHERE event_type = 'route_selected') THEN
    RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; a route_selected event exists after rollback (should have been refused)';
  END IF;

  -- Prior-phase baseline (Phase 1 through 4.1A) untouched.
  IF to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NULL
     OR to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NULL
     OR to_regclass('workflow_variables') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
  THEN RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; Phase 1 through 4.1A baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow gateway routing execution rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow gateway routing execution rollback validation PASSED (workflow_evaluate_gateway_condition and workflow_resolve_gateway_target absent, workflow_peek_final_graph_target/workflow_enter_downstream_node/workflow_transition_instance/workflow_advance_graph_step restored to their exact pre-4.2 Phase 4.1A bodies, decide_workflow_work_item untouched, no route_selected event present, Phase 1 through 4.1A baseline intact).';
END $$;
