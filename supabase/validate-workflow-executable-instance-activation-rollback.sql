-- CAP-002 Phase 2B.2 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  -- The two new tables must be gone.
  IF to_regclass('workflow_approval_rounds') IS NOT NULL
     OR to_regclass('workflow_approval_positions') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; a new table still exists';
  END IF;

  -- workflow_transition_instance must still exist (rollback restores
  -- its prior body, it never drops it) and must have reverted to the
  -- exact pre-2B.2 generic-only lifecycle logic with no activation
  -- branch remaining.
  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; workflow_transition_instance is missing';
  END IF;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%schema_version%'
     OR v_def ILIKE '%canonicalize_workflow_definition_payload%'
     OR v_def ILIKE '%v_is_executable%'
     OR v_def ILIKE '%workflow_approval_rounds%'
     OR v_def ILIKE '%workflow_approval_positions%'
  THEN RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; workflow_transition_instance still references activation logic'; END IF;

  -- The 5 public wrapper RPCs were never touched by this patch and
  -- must be unaffected by its rollback.
  IF to_regprocedure('public.start_workflow_instance(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.suspend_workflow_instance(uuid,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.resume_workflow_instance(uuid,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.cancel_workflow_instance(uuid,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.complete_workflow_instance(uuid,bigint,uuid,text)') IS NULL
  THEN RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; a wrapper RPC is missing'; END IF;

  -- Phase 2B.1's own canonicalizer and dual publish branch must be
  -- untouched by this rollback (this patch never modified them).
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; Phase 2B.1 canonicalizer missing';
  END IF;

  -- Phase 1/2 baseline (tables, RLS, other RPCs) untouched.
  IF to_regclass('workflow_definitions') IS NULL OR to_regclass('workflow_definition_versions') IS NULL
     OR to_regclass('workflow_instances') IS NULL OR to_regclass('workflow_events') IS NULL
     OR to_regclass('workflow_instance_steps') IS NULL OR to_regclass('workflow_tokens') IS NULL
     OR to_regclass('workflow_work_items') IS NULL
     OR to_regprocedure('create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; Phase 1/2 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 10
  THEN RAISE EXCEPTION 'Workflow executable instance activation rollback FAILED; unexpected workflow table count (expected the Phase 1/2B.1 baseline of 10, the 2 Phase 2B.2 tables must be gone)'; END IF;

  RAISE NOTICE 'Workflow executable instance activation rollback validation PASSED (new tables absent, workflow_transition_instance restored to its exact pre-2B.2 body, wrapper RPCs and Phase 1/2/2B.1 baseline intact).';
END $$;
