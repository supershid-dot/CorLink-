-- CorLink — T3F.2A structural/security validator
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_oid OID;
  v_src TEXT;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='search_tasks_for_dependency') <> 1 THEN
    RAISE EXCEPTION 'search_tasks_for_dependency must have exactly one overload';
  END IF;

  v_oid := to_regprocedure('public.search_tasks_for_dependency(uuid,text,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'expected picker signature missing'; END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_src;
  IF pg_get_function_result(v_oid) <> 'TABLE(id uuid, task_number text, title text, status text, priority text, due_date date)' THEN
    RAISE EXCEPTION 'picker return contract changed';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid=v_oid) THEN RAISE EXCEPTION 'picker is not SECURITY DEFINER'; END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid=v_oid) <> 's' THEN RAISE EXCEPTION 'picker is not STABLE'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid=v_oid AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
    RAISE EXCEPTION 'picker search_path is not pinned';
  END IF;
  IF EXISTS (
       SELECT 1 FROM pg_proc p, LATERAL aclexplode(COALESCE(p.proacl, acldefault('f',p.proowner))) acl
       WHERE p.oid=v_oid AND acl.grantee=0 AND acl.privilege_type='EXECUTE'
     ) OR has_function_privilege('anon',v_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'PUBLIC/anon may execute picker';
  END IF;
  IF NOT has_function_privilege('authenticated',v_oid,'EXECUTE') THEN RAISE EXCEPTION 'authenticated grant missing'; END IF;

  IF v_src !~ 'can_view_task\(current_task\.id\)' OR v_src !~ 'can_manage_task\(current_task\.id\)' THEN
    RAISE EXCEPTION 'current Task view/manage delegation missing';
  END IF;
  IF v_src !~ 'can_view_task\(candidate\.id\)' OR v_src !~ 'can_manage_task\(candidate\.id\)' THEN
    RAISE EXCEPTION 'candidate Task view/manage delegation missing';
  END IF;
  IF v_src !~ 'candidate\.organization_id = current_task\.organization_id'
     OR v_src !~ 'candidate\.id <> current_task\.id' THEN
    RAISE EXCEPTION 'organization or current-Task exclusion changed';
  END IF;
  IF v_src !~ 'td\.removed_at IS NULL' OR v_src !~ 'td\.dependent_task_id = candidate\.id' THEN
    RAISE EXCEPTION 'active forward/reverse dependency exclusions changed';
  END IF;
  IF v_src !~ 'LIMIT LEAST\(GREATEST\(COALESCE\(p_limit, 20\), 1\), 50\)' THEN
    RAISE EXCEPTION 'bounded limit changed';
  END IF;
  IF v_src !~ 'lower\(candidate\.task_number\).*LIKE' OR v_src !~ 'lower\(candidate\.title\).*LIKE' THEN
    RAISE EXCEPTION 'prefix search contract changed';
  END IF;
  IF v_src !~ 'candidate\.task_number, candidate\.title, candidate\.id' THEN
    RAISE EXCEPTION 'deterministic ordering changed';
  END IF;

  IF to_regprocedure('create_task_dependency(uuid,uuid)') IS NULL
     OR to_regprocedure('remove_task_dependency(uuid)') IS NULL
     OR to_regprocedure('list_task_dependencies(uuid,integer,integer)') IS NULL
     OR to_regprocedure('get_task_dependency_state(uuid)') IS NULL
     OR to_regprocedure('get_task_dependency_lifecycle_state(uuid)') IS NULL THEN
    RAISE EXCEPTION 'unrelated dependency foundation/lifecycle function missing';
  END IF;

  RAISE NOTICE 'TASK DEPENDENCY CANDIDATE MANAGEMENT validation PASSED';
END $$;
