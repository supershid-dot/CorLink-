-- CAP-002 Phase 3.2 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_def TEXT;
BEGIN
  -- The 14-arg (p_canonical) Phase 3.2 signature must be gone; the
  -- exact pre-3.2 13-arg signature must be restored.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; the 14-arg workflow_enter_downstream_node still exists';
  END IF;
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; the pre-3.2 13-arg workflow_enter_downstream_node is missing';
  END IF;

  -- The three new private helpers and the new read function must be gone.
  IF to_regprocedure('public.workflow_peek_final_graph_target(jsonb,uuid,uuid,uuid,text,jsonb)') IS NOT NULL
     OR to_regprocedure('public.workflow_resolve_approval_candidates(uuid,uuid,uuid,jsonb)') IS NOT NULL
     OR to_regprocedure('public.workflow_classify_approval_electorate(text,integer,integer)') IS NOT NULL
     OR to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NOT NULL
  THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; a Phase 3.2 helper/read function still exists'; END IF;

  -- The two new immutability triggers and trigger functions must be gone.
  IF EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgname IN (
      'workflow_approval_rounds_immutable_after_terminal',
      'workflow_approval_positions_immutable_after_terminal')
  ) THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; a Phase 3.2 immutability trigger still exists'; END IF;
  IF to_regprocedure('public.workflow_reject_terminal_round_mutation()') IS NOT NULL
     OR to_regprocedure('public.workflow_reject_terminal_position_mutation()') IS NOT NULL
  THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; a Phase 3.2 immutability trigger function still exists'; END IF;

  -- The three callers must be restored and must no longer reference the
  -- removed peek helper.
  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL
     OR to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
  THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; a restored caller function is missing'; END IF;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_peek_final_graph_target%' THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; workflow_transition_instance still references the removed peek helper';
  END IF;

  SELECT pg_get_functiondef('workflow_advance_graph_step(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_peek_final_graph_target%' THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; workflow_advance_graph_step still references the removed peek helper';
  END IF;

  SELECT pg_get_functiondef('decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_peek_final_graph_target%' THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; decide_workflow_work_item still references the removed peek helper';
  END IF;

  -- Prior-phase baseline (Phase 1/2/2B.1/2B.2/2B.2A/2C.1/3.1) untouched.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regprocedure('public.start_workflow_instance(uuid,bigint,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
  THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; Phase 1/2/2B.1/2B.2/2C.1/3.1 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow approval round lifecycle rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow approval round lifecycle rollback validation PASSED (14-arg workflow_enter_downstream_node and all Phase 3.2 helpers/triggers absent, pre-3.2 13-arg signature and callers restored byte-exact, Phase 1/2/2B.1/2B.2/2C.1/3.1 baseline intact).';
END $$;
