-- CorLink — Validate T3E.1 Task Relationships (read-only, hard-fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_type_def TEXT;
  v_create_def TEXT;
  v_remove_def TEXT;
  v_list_def TEXT;
BEGIN
  IF to_regclass('public.task_relationships') IS NULL THEN
    RAISE EXCEPTION 'Task Relationships validation FAILED: table missing';
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v_type_def
  FROM pg_constraint
  WHERE conrelid = 'task_relationships'::regclass AND conname = 'task_relationships_type_check';
  IF v_type_def IS NULL
     OR v_type_def NOT LIKE '%''related''%'
     OR v_type_def NOT LIKE '%''duplicate''%'
     OR v_type_def NOT LIKE '%''parent''%'
     OR regexp_count(v_type_def, '''[a-z_]+''') <> 3 THEN
    v_missing := v_missing || 'exact-stored-types ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'task_relationships'::regclass AND conname = 'task_relationships_no_self') THEN
    v_missing := v_missing || 'self-check ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = 'task_relationships'::regclass
      AND conname = 'task_relationships_canonical_direction'
      AND pg_get_constraintdef(oid) LIKE '%source_task_id < target_task_id%'
  ) THEN v_missing := v_missing || 'canonical-direction-check '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'public'
      AND indexname = 'idx_task_relationships_active_pair'
      AND indexdef LIKE '%UNIQUE%LEAST(source_task_id, target_task_id)%GREATEST(source_task_id, target_task_id)%'
      AND indexdef LIKE '%removed_at IS NULL%'
  ) THEN v_missing := v_missing || 'active-unordered-pair-unique-index '; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_task_relationships_source_active')
     OR NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_task_relationships_target_active') THEN
    v_missing := v_missing || 'endpoint-indexes ';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'task_relationships'::regclass) THEN
    v_missing := v_missing || 'rls ';
  END IF;
  IF (SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid WHERE c.relname = 'task_relationships' AND p.polcmd = 'r') <> 1 THEN
    v_missing := v_missing || 'single-select-policy ';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid WHERE c.relname = 'task_relationships' AND p.polcmd <> 'r') THEN
    v_missing := v_missing || 'direct-write-policy ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'task_relationships'
      AND pg_get_expr(p.polqual, p.polrelid) LIKE '%can_view_task(source_task_id)%'
      AND pg_get_expr(p.polqual, p.polrelid) LIKE '%can_view_task(target_task_id)%'
  ) THEN v_missing := v_missing || 'two-endpoint-visibility '; END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('create_task_relationship(uuid,uuid,text)'),
      ('remove_task_relationship(uuid)'),
      ('list_related_tasks(uuid)'),
      ('get_task_relationship_capabilities(uuid)'),
      ('can_view_task_relationship(uuid)')
    ) expected(signature)
    WHERE to_regprocedure(expected.signature) IS NULL
  ) THEN v_missing := v_missing || 'rpc-signatures '; END IF;
  IF EXISTS (
    SELECT proname FROM pg_proc WHERE proname IN (
      'create_task_relationship','remove_task_relationship','list_related_tasks',
      'get_task_relationship_capabilities','can_view_task_relationship'
    ) GROUP BY proname HAVING count(*) <> 1
  ) THEN v_missing := v_missing || 'stale-overloads '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname IN ('create_task_relationship','remove_task_relationship','list_related_tasks','get_task_relationship_capabilities','can_view_task_relationship')
      AND (NOT prosecdef OR proconfig IS NULL OR NOT ('search_path=public, pg_temp' = ANY(proconfig)))
  ) THEN v_missing := v_missing || 'rpc-hardening '; END IF;

  SELECT pg_get_functiondef('create_task_relationship(uuid,uuid,text)'::regprocedure) INTO v_create_def;
  SELECT pg_get_functiondef('remove_task_relationship(uuid)'::regprocedure) INTO v_remove_def;
  SELECT pg_get_functiondef('list_related_tasks(uuid)'::regprocedure) INTO v_list_def;
  IF v_create_def NOT LIKE '%can_manage_task(p_source_task_id)%OR NOT can_manage_task(p_target_task_id)%'
     OR v_create_def NOT LIKE '%v_source_org <> v_target_org%'
     OR v_create_def NOT LIKE '%pg_advisory_xact_lock%task_relationships:%'
     OR v_create_def NOT LIKE '%WITH RECURSIVE descendants%'
     OR v_create_def NOT LIKE '%LEAST(p_source_task_id, p_target_task_id)%'
     OR v_create_def LIKE '%''child''%' THEN
    v_missing := v_missing || 'create-authorization-canonical-lock-cycle ';
  END IF;
  IF v_remove_def NOT LIKE '%can_manage_task(v_relationship.source_task_id)%'
     OR v_remove_def NOT LIKE '%can_manage_task(v_relationship.target_task_id)%'
     OR v_remove_def NOT LIKE '%OR NOT can_manage_task(v_relationship.target_task_id)%' THEN
    v_missing := v_missing || 'remove-both-endpoint-management ';
  END IF;
  IF v_list_def NOT LIKE '%can_view_task(tr.source_task_id)%'
     OR v_list_def NOT LIKE '%can_view_task(tr.target_task_id)%'
     OR v_list_def NOT LIKE '%THEN ''child''%' THEN
    v_missing := v_missing || 'list-visibility-derived-child ';
  END IF;

  IF has_table_privilege('anon', 'task_relationships', 'SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated', 'task_relationships', 'INSERT,UPDATE,DELETE')
     OR NOT has_table_privilege('authenticated', 'task_relationships', 'SELECT') THEN
    v_missing := v_missing || 'table-grants ';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('create_task_relationship(uuid,uuid,text)'),('remove_task_relationship(uuid)'),
      ('list_related_tasks(uuid)'),('get_task_relationship_capabilities(uuid)'),('can_view_task_relationship(uuid)')
    ) expected(signature)
    WHERE has_function_privilege('anon', expected.signature, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', expected.signature, 'EXECUTE')
  ) THEN v_missing := v_missing || 'function-grants '; END IF;

  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task_relationship''%' FROM pg_constraint WHERE conname = 'audit_logs_record_type_check')
     OR NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'audit_select_task_relationships')
     OR pg_get_functiondef('can_view_task_relationship(uuid)'::regprocedure) NOT LIKE '%can_view_task(tr.source_task_id)%can_view_task(tr.target_task_id)%' THEN
    v_missing := v_missing || 'confidential-audit-visibility ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task Relationships validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Task Relationships validation PASSED';
END $$;
