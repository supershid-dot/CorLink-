-- CAP-002 Phase 2C.1 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  IF to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NOT NULL
     OR to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb)') IS NOT NULL
  THEN RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; a new function still exists'; END IF;

  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; workflow_transition_instance is missing';
  END IF;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_enter_downstream_node%'
  THEN RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; workflow_transition_instance still references the removed shared helper'; END IF;
  IF v_def NOT ILIKE '%next_event_sequence + 7 + LEAST%'
  THEN RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; restored body does not carry the Phase 2B.2A correction'; END IF;

  -- Phase 1/2/2B.1/2B.2/2B.2A baseline untouched.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regprocedure('public.start_workflow_instance(uuid,bigint,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; Phase 1/2/2B.1/2B.2 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow graph advancement foundation rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow graph advancement foundation rollback validation PASSED (new functions absent, workflow_transition_instance restored to its exact pre-2C.1/Phase 2B.2A-corrected body, Phase 1/2/2B.1/2B.2 baseline intact).';
END $$;
