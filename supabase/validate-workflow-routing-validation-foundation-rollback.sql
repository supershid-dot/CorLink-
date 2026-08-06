-- CAP-002 Phase 4.1 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  IF to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; set_workflow_instance_variable still exists';
  END IF;
  IF to_regprocedure('public.wf_condition_literal_matches_type(jsonb,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; wf_condition_literal_matches_type still exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='workflow_variables' AND column_name IN ('lock_version','write_idempotency_key')
  ) THEN RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; workflow_variables still carries lock_version/write_idempotency_key'; END IF;

  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; canonicalize_workflow_definition_payload is missing';
  END IF;
  SELECT pg_get_functiondef('canonicalize_workflow_definition_payload(jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' OR v_def ILIKE '%wf_condition_literal_matches_type%' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; canonicalize_workflow_definition_payload still carries capability-version-2 gateway logic';
  END IF;
  IF v_def NOT ILIKE '%''1''%' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; restored canonicalize does not carry the schema_version=1-only check';
  END IF;

  SELECT pg_get_functiondef('publish_workflow_definition_version(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%schema_version%)::integer%' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; publish_workflow_definition_version still carries the generalized capability-version check';
  END IF;
  IF v_def NOT ILIKE '%capability_version <> 1%' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; publish_workflow_definition_version does not carry the exact pre-4.1 hardcoded capability_version <> 1 check';
  END IF;

  FOREACH v_def IN ARRAY ARRAY[
    'create_workflow_definition(uuid,text,text,text,jsonb,uuid)',
    'create_workflow_definition_version(uuid,jsonb,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; % is missing', v_def;
    END IF;
  END LOOP;
  SELECT pg_get_functiondef('create_workflow_definition(uuid,text,text,text,jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%v_capability_version%' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; create_workflow_definition still computes v_capability_version';
  END IF;

  -- Prior-phase baseline (Phase 1 through 3.2) untouched.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NULL
     OR to_regclass('workflow_variables') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
  THEN RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; Phase 1/2B.1/2C.1/3.1/3.2 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow routing validation foundation rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow routing validation foundation rollback validation PASSED (set_workflow_instance_variable and wf_condition_literal_matches_type absent, workflow_variables restored to its pre-4.1 shape, canonicalize/create/publish restored to their exact pre-4.1 Phase 2B.1 bodies, Phase 1 through 3.2 baseline intact).';
END $$;
