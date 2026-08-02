-- CAP-002 Phase 2 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_signature TEXT; v_present TEXT := '';
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'workflow_transition_instance(uuid,text,bigint,uuid,text,text)',
    'start_workflow_instance(uuid,bigint,uuid)',
    'suspend_workflow_instance(uuid,bigint,uuid,text)',
    'resume_workflow_instance(uuid,bigint,uuid,text)',
    'cancel_workflow_instance(uuid,bigint,uuid,text)',
    'complete_workflow_instance(uuid,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure('public.'||v_signature) IS NOT NULL THEN
      v_present:=v_present||v_signature||' ';
    END IF;
  END LOOP;
  IF v_present<>'' THEN RAISE EXCEPTION 'Workflow runtime rollback validation FAILED; functions remain: %',v_present; END IF;

  IF to_regclass('workflow_definitions') IS NULL
     OR to_regclass('workflow_definition_versions') IS NULL
     OR to_regclass('workflow_instances') IS NULL
     OR to_regclass('workflow_instance_steps') IS NULL
     OR to_regclass('workflow_tokens') IS NULL
     OR to_regclass('workflow_work_items') IS NULL
     OR to_regclass('workflow_participants') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
     OR to_regclass('workflow_variables') IS NULL
     OR to_regclass('workflow_events') IS NULL
     OR to_regprocedure('create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)') IS NULL
     OR to_regprocedure('get_workflow_instance(uuid)') IS NULL
     OR to_regclass('requests') IS NULL OR to_regclass('external_correspondence') IS NULL
     OR to_regclass('internal_requests') IS NULL OR to_regclass('prisoner_letters') IS NULL
     OR to_regclass('meetings') IS NULL OR to_regclass('tasks') IS NULL
     OR to_regclass('notifications') IS NULL OR to_regclass('audit_logs') IS NULL
  THEN RAISE EXCEPTION 'Workflow runtime rollback validation FAILED; Phase 1 or module baseline drift'; END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='workflow_instances'::regclass)
     OR (SELECT count(*) FROM pg_policy WHERE polrelid='workflow_instances'::regclass AND polcmd='r')<>1
  THEN RAISE EXCEPTION 'Workflow runtime rollback validation FAILED; Phase 1 RLS drift'; END IF;

  RAISE NOTICE 'Workflow runtime rollback validation PASSED (Phase 2 functions absent; Phase 1 and module baseline intact).';
END $$;
