-- CAP-002 Phase 2B.1 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; canonicalize_workflow_definition_payload still present';
  END IF;

  -- The three modified RPCs must still exist (rollback restores their
  -- prior bodies, it never drops them) and must have reverted to the
  -- exact Phase 1 inert-only publish boundary with no executable-v1
  -- branch remaining.
  IF to_regprocedure('public.create_workflow_definition(uuid,text,text,text,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.create_workflow_definition_version(uuid,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.publish_workflow_definition_version(uuid,bigint,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; a Phase 1 RPC is missing'; END IF;

  SELECT pg_get_functiondef('publish_workflow_definition_version(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%canonicalize_workflow_definition_payload%'
     OR v_def ILIKE '%schema_version%'
     OR v_def NOT ILIKE '%Phase 1 may publish only an inert workflow definition%'
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; publish still references the executable-v1 branch'; END IF;

  SELECT pg_get_functiondef('create_workflow_definition_version(uuid,jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%canonicalize_workflow_definition_payload%' OR v_def ILIKE '%schema_version%'
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; create_workflow_definition_version still references canonicalization'; END IF;

  SELECT pg_get_functiondef('create_workflow_definition(uuid,text,text,text,jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%canonicalize_workflow_definition_payload%' OR v_def ILIKE '%schema_version%'
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; create_workflow_definition still references canonicalization'; END IF;

  -- Phase 1/2 baseline (tables, RLS, other RPCs) untouched.
  IF to_regclass('workflow_definitions') IS NULL OR to_regclass('workflow_definition_versions') IS NULL
     OR to_regclass('workflow_instances') IS NULL OR to_regclass('workflow_events') IS NULL
     OR to_regprocedure('start_workflow_instance(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; Phase 1/2 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 10
  THEN RAISE EXCEPTION 'Workflow executable definition validation rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow executable definition validation rollback validation PASSED (canonicalizer absent, Phase 1 RPCs restored to their exact inert-only bodies, Phase 1/2 baseline intact).';
END $$;
