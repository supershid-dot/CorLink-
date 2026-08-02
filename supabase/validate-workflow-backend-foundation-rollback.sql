-- CAP-002 Phase 1 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_name TEXT; v_present TEXT := '';
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'workflow_definitions','workflow_definition_versions','workflow_instances',
    'workflow_instance_steps','workflow_tokens','workflow_work_items',
    'workflow_participants','workflow_decisions','workflow_variables','workflow_events'
  ] LOOP
    IF to_regclass('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  FOREACH v_name IN ARRAY ARRAY[
    'workflow_actor_is_active()','can_manage_workflow_definition(uuid)',
    'can_view_workflow_instance(uuid)','can_manage_workflow_instance(uuid)',
    'create_workflow_definition(uuid,text,text,text,jsonb,uuid)',
    'create_workflow_definition_version(uuid,jsonb,uuid)',
    'publish_workflow_definition_version(uuid,bigint,uuid)',
    'create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)',
    'get_workflow_instance(uuid)','list_workflow_work_items(integer,timestamp with time zone,uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  IF v_present<>'' THEN RAISE EXCEPTION 'Workflow rollback validation FAILED; objects remain: %',v_present; END IF;
  IF to_regclass('public.requests') IS NULL OR to_regclass('public.external_correspondence') IS NULL
     OR to_regclass('public.meetings') IS NULL OR to_regclass('public.tasks') IS NULL
     OR to_regclass('public.task_relationships') IS NULL OR to_regclass('public.task_dependencies') IS NULL
     OR to_regclass('public.notifications') IS NULL OR to_regclass('public.audit_logs') IS NULL
     OR to_regclass('public.attachments') IS NULL
  THEN RAISE EXCEPTION 'Workflow rollback validation FAILED; approved baseline object missing'; END IF;
  RAISE NOTICE 'Workflow backend rollback validation PASSED (foundation absent; approved baseline intact).';
END $$;
