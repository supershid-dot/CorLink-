-- CAP-002 Phase 1 workflow foundation structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_name TEXT;
  v_def TEXT;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'workflow_definitions','workflow_definition_versions','workflow_instances',
    'workflow_instance_steps','workflow_tokens','workflow_work_items',
    'workflow_participants','workflow_decisions','workflow_variables','workflow_events'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      v_missing := v_missing || v_name || ' ';
    ELSIF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || v_name)) THEN
      v_missing := v_missing || v_name || '-rls ';
    ELSIF (SELECT count(*) FROM pg_policy WHERE polrelid = to_regclass('public.' || v_name) AND polcmd = 'r') <> 1
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = to_regclass('public.' || v_name) AND polcmd <> 'r') THEN
      v_missing := v_missing || v_name || '-select-only-policy ';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated')
      AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  FOREACH v_name IN ARRAY ARRAY[
    'workflow_actor_is_active()','can_manage_workflow_definition(uuid)',
    'can_view_workflow_instance(uuid)','can_manage_workflow_instance(uuid)',
    'create_workflow_definition(uuid,text,text,text,jsonb,uuid)',
    'create_workflow_definition_version(uuid,jsonb,uuid)',
    'publish_workflow_definition_version(uuid,bigint,uuid)',
    'create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)',
    'get_workflow_instance(uuid)',
    'list_workflow_work_items(integer,timestamp with time zone,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_name) IS NULL THEN
      v_missing := v_missing || v_name || ' ';
    ELSE
      IF NOT (SELECT prosecdef FROM pg_proc WHERE oid=to_regprocedure('public.'||v_name))
         OR NOT EXISTS (
           SELECT 1 FROM pg_proc p
           WHERE p.oid=to_regprocedure('public.'||v_name)
             AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
         ) THEN
        v_missing := v_missing || v_name || '-security ';
      END IF;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN (
      'create_workflow_definition','create_workflow_definition_version',
      'publish_workflow_definition_version','create_workflow_instance',
      'get_workflow_instance','list_workflow_work_items'
    ) AND has_function_privilege('anon',p.oid,'EXECUTE')
  ) THEN v_missing := v_missing || 'anon-rpc-execute '; END IF;

  SELECT pg_get_functiondef('publish_workflow_definition_version(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%jsonb_array_length%nodes%'
     OR v_def NOT ILIKE '%jsonb_array_length%edges%'
     OR v_def ILIKE '%advance_workflow%'
  THEN v_missing := v_missing || 'inert-publish-boundary '; END IF;

  SELECT pg_get_functiondef('create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%pg_advisory_xact_lock%'
     OR v_def NOT ILIKE '%workflow_active_subject:%'
     OR v_def ILIKE '%requests%'
     OR v_def ILIKE '%tasks%'
     OR v_def ILIKE '%notifications%'
  THEN v_missing := v_missing || 'instance-boundary '; END IF;

  IF to_regprocedure('public.advance_workflow(uuid)') IS NOT NULL
     OR to_regprocedure('public.cancel_workflow(uuid)') IS NOT NULL
     OR to_regprocedure('public.complete_workflow(uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'runtime-rpc-present '; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='workflow_events'::regclass AND tgname='workflow_events_immutable' AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='workflow_decisions'::regclass AND tgname='workflow_decisions_immutable' AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='workflow_definition_versions'::regclass AND tgname='workflow_definition_versions_immutable' AND NOT tgisinternal)
  THEN v_missing := v_missing || 'immutability-triggers '; END IF;

  FOREACH v_name IN ARRAY ARRAY[
    'idx_workflow_definitions_scope_key','idx_workflow_definition_versions_lookup',
    'idx_workflow_instances_one_active_subject','idx_workflow_instances_org_status',
    'idx_workflow_instance_steps_current','idx_workflow_tokens_active',
    'idx_workflow_work_items_assignee_queue','idx_workflow_work_items_org_queue',
    'idx_workflow_participants_user_active','idx_workflow_decisions_instance',
    'idx_workflow_variables_instance','idx_workflow_events_instance_sequence',
    'idx_workflow_events_correlation','idx_workflow_events_created_brin'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN v_missing := v_missing || v_name || ' '; END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid='workflow_instances'::regclass
      AND conname='workflow_instances_version_definition_fkey'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid='workflow_definitions'::regclass
      AND conname='workflow_definitions_active_version_fkey'
  ) THEN v_missing := v_missing || 'version-pinning-fks '; END IF;

  IF to_regclass('public.requests') IS NULL OR to_regclass('public.tasks') IS NULL
     OR to_regclass('public.task_relationships') IS NULL OR to_regclass('public.task_links') IS NULL
     OR to_regclass('public.notifications') IS NULL OR to_regclass('public.audit_logs') IS NULL
  THEN v_missing := v_missing || 'baseline-regression '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow backend foundation validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow backend foundation validation PASSED (10 tables, 10 secured functions, SELECT-only RLS, immutable history, inert boundary, indexes and baseline objects).';
END $$;
