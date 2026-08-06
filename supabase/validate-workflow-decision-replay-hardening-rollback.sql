-- CAP-002 Phase 4.3 decision-replay hardening rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT; v_fn CONSTANT TEXT := 'public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)';
BEGIN
  IF to_regprocedure(v_fn) IS NULL THEN
    RAISE EXCEPTION 'Workflow decision replay hardening rollback FAILED; decide_workflow_work_item is missing';
  END IF;
  -- Checks for the quoted metadata-key read specifically, not the
  -- bare parameter name (p_expected_instance_lock_version /
  -- p_expected_work_item_lock_version are ordinary function
  -- arguments present in both the pre- and post-fix bodies).
  SELECT pg_get_functiondef(to_regprocedure(v_fn)) INTO v_def;
  IF v_def ILIKE '%metadata ->> ''expected_instance_lock_version''%'
     OR v_def ILIKE '%metadata ->> ''expected_work_item_lock_version''%' THEN
    RAISE EXCEPTION 'Workflow decision replay hardening rollback FAILED; decide_workflow_work_item still carries the Phase 4.3 expected-lock-version comparison';
  END IF;
  IF NOT has_function_privilege('authenticated', to_regprocedure(v_fn), 'EXECUTE')
     OR has_function_privilege('anon', to_regprocedure(v_fn), 'EXECUTE') THEN
    RAISE EXCEPTION 'Workflow decision replay hardening rollback FAILED; grants drifted';
  END IF;

  -- Prior-phase baseline (everything through Phase 4.2) untouched —
  -- this rollback only ever restores one function body.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL
     OR to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
  THEN RAISE EXCEPTION 'Workflow decision replay hardening rollback FAILED; Phase 1 through 4.2 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow decision replay hardening rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow decision replay hardening rollback validation PASSED (decide_workflow_work_item restored to its exact pre-4.3 body, grants intact, Phase 1 through 4.2 baseline intact).';
END $$;
