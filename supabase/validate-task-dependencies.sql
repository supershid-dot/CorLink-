-- CorLink — validate T3F.1 Task Dependency Backend Foundation (hard-fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_create TEXT;
  v_remove TEXT;
  v_list TEXT;
  v_state TEXT;
  v_search TEXT;
BEGIN
  IF to_regclass('public.task_dependencies') IS NULL THEN
    RAISE EXCEPTION 'Task Dependency validation FAILED: task_dependencies missing';
  END IF;
  IF to_regclass('public.task_dependency_waivers') IS NULL THEN
    v_missing := v_missing || 'waiver-table ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('id','uuid','gen_random_uuid()'),
      ('dependent_task_id','uuid',NULL),
      ('prerequisite_task_id','uuid',NULL),
      ('organization_id','uuid',NULL),
      ('created_by','uuid',NULL),
      ('created_at','timestamp with time zone','now()'),
      ('removed_by','uuid',NULL),
      ('removed_at','timestamp with time zone',NULL)
    ) expected(column_name,data_type,column_default)
    LEFT JOIN information_schema.columns c
      ON c.table_schema='public' AND c.table_name='task_dependencies'
     AND c.column_name=expected.column_name
    WHERE c.column_name IS NULL OR c.data_type<>expected.data_type
      OR (expected.column_default IS NOT NULL AND c.column_default NOT LIKE '%'||expected.column_default||'%')
  ) THEN v_missing := v_missing || 'dependency-columns-defaults '; END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('id'),('dependency_id'),('waived_by'),('waived_at'),('reason')
    ) expected(column_name)
    LEFT JOIN information_schema.columns c
      ON c.table_schema='public' AND c.table_name='task_dependency_waivers'
     AND c.column_name=expected.column_name
    WHERE c.column_name IS NULL
  ) THEN v_missing := v_missing || 'waiver-columns '; END IF;

  IF (SELECT count(*) FROM pg_constraint
      WHERE conrelid='task_dependencies'::regclass AND contype='f')<>5
     OR EXISTS (
       SELECT 1 FROM pg_constraint
       WHERE conrelid='task_dependencies'::regclass AND contype='f'
         AND confdeltype<>'r'
     ) THEN v_missing := v_missing || 'dependency-restrict-fks '; END IF;
  IF (SELECT count(*) FROM pg_constraint
      WHERE conrelid='task_dependency_waivers'::regclass AND contype='f')<>2
     OR EXISTS (
       SELECT 1 FROM pg_constraint
       WHERE conrelid='task_dependency_waivers'::regclass AND contype='f'
         AND confdeltype<>'r'
     ) THEN v_missing := v_missing || 'waiver-restrict-fks '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid='task_dependencies'::regclass
      AND conname='task_dependencies_no_self'
      AND pg_get_constraintdef(oid) LIKE '%dependent_task_id <> prerequisite_task_id%'
  ) THEN v_missing := v_missing || 'self-check '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid='task_dependencies'::regclass
      AND tgname='task_dependency_endpoint_guard' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'endpoint-org-trigger '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname='public'
      AND indexname='idx_task_dependencies_active_pair'
      AND indexdef LIKE '%UNIQUE%dependent_task_id, prerequisite_task_id%'
      AND indexdef LIKE '%removed_at IS NULL%'
  ) THEN v_missing := v_missing || 'active-directed-unique '; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_task_dependencies_dependent_active')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_task_dependencies_prerequisite_active')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_task_dependencies_org_graph_active')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_task_dependency_waivers_dependency')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_tasks_dependency_picker_number')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='idx_tasks_dependency_picker_title') THEN
    v_missing := v_missing || 'purpose-indexes ';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='task_dependencies'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='task_dependency_waivers'::regclass) THEN
    v_missing := v_missing || 'rls-enabled ';
  END IF;
  IF (SELECT count(*) FROM pg_policy WHERE polrelid='task_dependencies'::regclass AND polcmd='r')<>1
     OR (SELECT count(*) FROM pg_policy WHERE polrelid='task_dependency_waivers'::regclass AND polcmd='r')<>1
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid IN ('task_dependencies'::regclass,'task_dependency_waivers'::regclass) AND polcmd<>'r') THEN
    v_missing := v_missing || 'select-only-policies ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy WHERE polrelid='task_dependencies'::regclass
      AND pg_get_expr(polqual,polrelid) LIKE '%can_view_task(dependent_task_id)%'
      AND pg_get_expr(polqual,polrelid) LIKE '%can_view_task(prerequisite_task_id)%'
  ) THEN v_missing := v_missing || 'two-sided-visibility '; END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('create_task_dependency(uuid,uuid)'),
      ('remove_task_dependency(uuid)'),
      ('list_task_dependencies(uuid,integer,integer)'),
      ('get_task_dependency_capabilities(uuid)'),
      ('search_tasks_for_dependency(uuid,text,integer)'),
      ('task_dependency_would_cycle(uuid,uuid)'),
      ('get_task_dependency_state(uuid)'),
      ('enforce_task_dependency_endpoints()')
    ) expected(signature)
    WHERE to_regprocedure(expected.signature) IS NULL
  ) THEN v_missing := v_missing || 'function-signatures '; END IF;
  IF EXISTS (
    SELECT proname FROM pg_proc
    WHERE proname IN ('create_task_dependency','remove_task_dependency','list_task_dependencies',
      'get_task_dependency_capabilities','search_tasks_for_dependency','task_dependency_would_cycle',
      'get_task_dependency_state','enforce_task_dependency_endpoints')
    GROUP BY proname HAVING count(*)<>1
  ) THEN v_missing := v_missing || 'stale-overloads '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname IN ('create_task_dependency','remove_task_dependency','list_task_dependencies',
      'get_task_dependency_capabilities','search_tasks_for_dependency','task_dependency_would_cycle','get_task_dependency_state')
      AND (NOT prosecdef OR proconfig IS NULL OR NOT ('search_path=public, pg_temp'=ANY(proconfig)))
  ) OR EXISTS (
    SELECT 1 FROM pg_proc WHERE proname='enforce_task_dependency_endpoints'
      AND (proconfig IS NULL OR NOT ('search_path=public, pg_temp'=ANY(proconfig)))
  ) THEN v_missing := v_missing || 'function-hardening '; END IF;

  SELECT pg_get_functiondef('create_task_dependency(uuid,uuid)'::regprocedure) INTO v_create;
  SELECT pg_get_functiondef('remove_task_dependency(uuid)'::regprocedure) INTO v_remove;
  SELECT pg_get_functiondef('list_task_dependencies(uuid,integer,integer)'::regprocedure) INTO v_list;
  SELECT pg_get_functiondef('get_task_dependency_state(uuid)'::regprocedure) INTO v_state;
  SELECT pg_get_functiondef('search_tasks_for_dependency(uuid,text,integer)'::regprocedure) INTO v_search;
  IF v_create NOT LIKE '%can_manage_task(p_dependent_task_id)%'
     OR v_create NOT LIKE '%can_manage_task(p_prerequisite_task_id)%'
     OR v_create NOT LIKE '%pg_advisory_xact_lock%task_dependencies:%'
     OR v_create NOT LIKE '%task_dependency_would_cycle%'
     OR v_create LIKE '%dependency_type%' THEN
    v_missing := v_missing || 'create-auth-lock-cycle-no-type ';
  END IF;
  IF v_remove NOT LIKE '%can_manage_task(v_dependency.dependent_task_id)%'
     OR v_remove NOT LIKE '%can_manage_task(v_dependency.prerequisite_task_id)%'
     OR v_remove NOT LIKE '%pg_advisory_xact_lock%task_dependencies:%' THEN
    v_missing := v_missing || 'remove-both-manage-lock ';
  END IF;
  IF v_list NOT LIKE '%THEN ''depends_on'' ELSE ''blocks''%'
     OR v_list NOT LIKE '%can_view_task(td.dependent_task_id)%'
     OR v_list NOT LIKE '%can_view_task(td.prerequisite_task_id)%'
     OR v_list NOT LIKE '%LIMIT LEAST%100%' THEN
    v_missing := v_missing || 'list-derived-visibility-bounded ';
  END IF;
  IF v_state NOT LIKE '%status <> ''completed''%'
     OR v_state NOT LIKE '%task_dependency_waivers%' THEN
    v_missing := v_missing || 'derived-state-completion-waiver ';
  END IF;
  IF v_search NOT LIKE '%can_view_task(current_task.id)%'
     OR v_search NOT LIKE '%can_view_task(candidate.id)%'
     OR v_search NOT LIKE '%candidate.organization_id = current_task.organization_id%'
     OR v_search NOT LIKE '%candidate.id <> current_task.id%'
     OR v_search NOT LIKE '%LIMIT LEAST%50%' THEN
    v_missing := v_missing || 'search-visible-same-org-bounded ';
  END IF;

  IF has_table_privilege('anon','task_dependencies','SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','task_dependencies','INSERT,UPDATE,DELETE')
     OR NOT has_table_privilege('authenticated','task_dependencies','SELECT')
     OR has_table_privilege('anon','task_dependency_waivers','SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','task_dependency_waivers','INSERT,UPDATE,DELETE')
     OR NOT has_table_privilege('authenticated','task_dependency_waivers','SELECT') THEN
    v_missing := v_missing || 'table-grants ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('create_task_dependency(uuid,uuid)'),('remove_task_dependency(uuid)'),
      ('list_task_dependencies(uuid,integer,integer)'),('get_task_dependency_capabilities(uuid)'),
      ('search_tasks_for_dependency(uuid,text,integer)')
    ) public_rpc(signature)
    WHERE has_function_privilege('anon',signature,'EXECUTE')
       OR NOT has_function_privilege('authenticated',signature,'EXECUTE')
  ) OR EXISTS (
    SELECT 1 FROM (VALUES
      ('task_dependency_would_cycle(uuid,uuid)'),('get_task_dependency_state(uuid)'),
      ('enforce_task_dependency_endpoints()')
    ) private_helper(signature)
    WHERE has_function_privilege('anon',signature,'EXECUTE')
       OR has_function_privilege('authenticated',signature,'EXECUTE')
  ) THEN v_missing := v_missing || 'function-grants-private-helpers '; END IF;

  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task_dependency''%'
          FROM pg_constraint WHERE conname='audit_logs_record_type_check')
     OR NOT (SELECT pg_get_constraintdef(oid) LIKE '%task_dependency_added%task_dependency_removed%task_dependency_waived%'
             FROM pg_constraint WHERE conname='audit_logs_action_check')
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy WHERE polname='audit_select_task_dependencies'
         AND pg_get_expr(polqual,polrelid) LIKE '%can_view_task(td.dependent_task_id)%'
         AND pg_get_expr(polqual,polrelid) LIKE '%can_view_task(td.prerequisite_task_id)%'
     ) THEN v_missing := v_missing || 'audit-registration-visibility '; END IF;

  IF to_regclass('public.task_relationships') IS NULL
     OR to_regclass('public.task_links') IS NULL
     OR to_regclass('public.attachments') IS NULL
     OR to_regprocedure('list_task_request_links(uuid,integer,integer)') IS NULL
     OR to_regprocedure('list_task_meeting_links(uuid,integer,integer)') IS NULL
     OR to_regprocedure('list_task_internal_collaboration_links(uuid,integer,integer)') IS NULL
     OR to_regprocedure('list_task_entry_links(uuid,integer,integer)') IS NULL
     OR to_regprocedure('list_task_prisoner_letter_links(uuid,integer,integer)') IS NULL THEN
    v_missing := v_missing || 'approved-task-surfaces-regression ';
  END IF;

  IF v_missing<>'' THEN
    RAISE EXCEPTION 'Task Dependency validation FAILED: %',v_missing;
  END IF;
  RAISE NOTICE 'Task Dependency validation PASSED';
END $$;
