-- CAP-002 Phase 2B.2A rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Workflow activation event sequence correction rollback FAILED; workflow_transition_instance is missing';
  END IF;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%next_event_sequence + 5 + v_electorate_count + LEAST%'
     OR v_def ILIKE '%next_event_sequence + 7 + LEAST%'
  THEN RAISE EXCEPTION 'Workflow activation event sequence correction rollback FAILED; corrected formula still present'; END IF;

  -- Everything else about activation (2B.2), definition validation
  -- (2B.1), and the runtime/foundation baseline must remain intact —
  -- this rollback touches exactly one function's one expression.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regprocedure('public.start_workflow_instance(uuid,bigint,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Workflow activation event sequence correction rollback FAILED; Phase 2B.1/2B.2 baseline drift'; END IF;

  RAISE NOTICE 'Workflow activation event sequence correction rollback validation PASSED (workflow_transition_instance restored to its exact pre-correction body, Phase 2B.1/2B.2 baseline intact).';
END $$;
