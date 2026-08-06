-- CAP-002 Phase 5.1 delegation/substitution foundation rollback
-- validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_name TEXT; v_present TEXT := '';
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'workflow_delegations','workflow_delegation_events',
    'workflow_substitutions','workflow_substitution_events'
  ] LOOP
    IF to_regclass('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  FOREACH v_name IN ARRAY ARRAY[
    'create_workflow_delegation(uuid,uuid,uuid,jsonb,text,text,timestamptz,timestamptz,text,uuid)',
    'accept_workflow_delegation(uuid,bigint,uuid)',
    'reject_workflow_delegation(uuid,bigint,text,uuid)',
    'revoke_workflow_delegation(uuid,bigint,text,uuid)',
    'get_workflow_delegation(uuid)',
    'list_workflow_delegations(uuid,text,integer,timestamptz,uuid)',
    'create_workflow_substitution(uuid,jsonb,uuid,text,timestamptz,timestamptz,text,uuid)',
    'revoke_workflow_substitution(uuid,bigint,text,uuid)',
    'get_workflow_substitution(uuid)',
    'list_workflow_substitutions(uuid,text,integer,timestamptz,uuid)',
    'workflow_delegation_visible_to_caller(uuid,uuid,uuid)',
    'workflow_substitution_visible_to_caller(text,uuid,uuid,uuid)',
    'can_manage_workflow_delegation_scope(uuid)',
    'workflow_reject_terminal_delegation_mutation()',
    'workflow_reject_delegation_event_mutation()',
    'workflow_reject_terminal_substitution_mutation()'
  ] LOOP
    IF to_regprocedure('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  IF v_present<>'' THEN RAISE EXCEPTION 'Workflow delegation/substitution foundation rollback validation FAILED; objects remain: %',v_present; END IF;

  -- btree_gist is deliberately NOT dropped by this rollback (a
  -- sibling CAP also depends on it) and must remain present.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gist') THEN
    RAISE EXCEPTION 'Workflow delegation/substitution foundation rollback validation FAILED; btree_gist was unexpectedly removed';
  END IF;

  -- Phase 1 through 4.3 baseline intact — this rollback touches only
  -- the four objects it created.
  IF to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regclass('public.workflow_approval_rounds') IS NULL
     OR to_regclass('public.workflow_variables') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL
  THEN RAISE EXCEPTION 'Workflow delegation/substitution foundation rollback validation FAILED; Phase 1 through 4.3 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow delegation/substitution foundation rollback validation FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow delegation/substitution foundation rollback validation PASSED (all four new tables and every RPC/helper/trigger absent, btree_gist preserved, Phase 1 through 4.3 baseline intact).';
END $$;
