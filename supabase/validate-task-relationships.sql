-- CorLink — Validate T3E Task Relationships (read-only)
\set ON_ERROR_STOP on

DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF to_regclass('public.task_relationships') IS NULL THEN
    RAISE EXCEPTION 'Task Relationships validation FAILED: table missing';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'task_relationships'::regclass) THEN
    v_missing := v_missing || 'rls ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'task_relationships' AND p.polname = 'task_relationships_select' AND p.polcmd = 'r'
  ) THEN v_missing := v_missing || 'select-policy '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'task_relationships' AND p.polcmd <> 'r'
  ) THEN v_missing := v_missing || 'unexpected-write-policy '; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_task_relationships_active_pair') THEN
    v_missing := v_missing || 'active-pair-index ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'task_relationships'::regclass
      AND pg_get_constraintdef(oid) LIKE '%source_task_id <> target_task_id%'
  ) THEN v_missing := v_missing || 'self-check '; END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('create_task_relationship'), ('remove_task_relationship'),
      ('list_related_tasks'), ('get_task_relationship_capabilities')
    ) expected(name)
    WHERE NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = expected.name)
  ) THEN v_missing := v_missing || 'rpc '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname IN ('create_task_relationship', 'remove_task_relationship', 'list_related_tasks', 'get_task_relationship_capabilities')
      AND (NOT prosecdef OR proconfig IS NULL OR NOT ('search_path=public, pg_temp' = ANY(proconfig)))
  ) THEN v_missing := v_missing || 'rpc-hardening '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'task_relationships'
      AND pg_get_expr(p.polqual, p.polrelid) LIKE '%can_view_task(source_task_id)%'
      AND pg_get_expr(p.polqual, p.polrelid) LIKE '%can_view_task(target_task_id)%'
  ) THEN v_missing := v_missing || 'visibility-delegation '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task Relationships validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Task Relationships validation PASSED';
END $$;
