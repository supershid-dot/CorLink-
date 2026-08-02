-- CorLink - validate T3F.2 Task Dependency Lifecycle Enforcement (hard-fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_update TEXT;
  v_complete TEXT;
  v_create TEXT;
  v_cancel TEXT;
  v_state TEXT;
BEGIN
  IF to_regprocedure('public.get_task_dependency_state(uuid)') IS NULL
     OR to_regprocedure('public.get_task_dependency_lifecycle_state(uuid)') IS NULL THEN
    v_missing := v_missing || 'state-functions ';
  END IF;
  IF to_regprocedure('public.update_task(uuid,text,text,text,text,date,date,uuid,text)') IS NULL
     OR to_regprocedure('public.complete_task(uuid,text)') IS NULL
     OR to_regprocedure('public.cancel_task(uuid,text)') IS NULL THEN
    v_missing := v_missing || 'lifecycle-signatures ';
  END IF;

  IF EXISTS (
    SELECT proname FROM pg_proc
    WHERE proname IN ('create_task_dependency','update_task','complete_task','get_task_dependency_lifecycle_state')
    GROUP BY proname HAVING count(*) <> 1
  ) THEN v_missing := v_missing || 'stale-overloads '; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname IN ('create_task_dependency','update_task','complete_task','get_task_dependency_lifecycle_state')
      AND (NOT prosecdef OR proconfig IS NULL OR NOT ('search_path=public, pg_temp'=ANY(proconfig)))
  ) THEN v_missing := v_missing || 'function-hardening '; END IF;

  SELECT pg_get_functiondef('update_task(uuid,text,text,text,text,date,date,uuid,text)'::regprocedure) INTO v_update;
  SELECT pg_get_functiondef('complete_task(uuid,text)'::regprocedure) INTO v_complete;
  SELECT pg_get_functiondef('create_task_dependency(uuid,uuid)'::regprocedure) INTO v_create;
  SELECT pg_get_functiondef('cancel_task(uuid,text)'::regprocedure) INTO v_cancel;
  SELECT pg_get_functiondef('get_task_dependency_lifecycle_state(uuid)'::regprocedure) INTO v_state;

  IF v_create NOT LIKE '%pg_advisory_xact_lock%task_dependencies:%'
     OR v_create NOT LIKE '%ORDER BY id%FOR UPDATE%'
     OR (length(v_create)-length(replace(v_create,'v_dependent.status NOT IN','')))/length('v_dependent.status NOT IN') < 2
     OR v_create NOT LIKE '%task_dependency_would_cycle%'
     OR v_create NOT LIKE '%task_dependency_added%' THEN
    v_missing := v_missing || 'create-race-hardening-preservation ';
  END IF;

  IF v_update NOT LIKE '%p_status = ''in_progress''%'
     OR v_update NOT LIKE '%valid_task_status_transition(v_task.status, ''in_progress'')%'
     OR v_update NOT LIKE '%pg_advisory_xact_lock%task_dependencies:%'
     OR v_update NOT LIKE '%FOR UPDATE%'
     OR v_update NOT LIKE '%get_task_dependency_state(p_task_id)%'
     OR v_update NOT LIKE '%Task cannot be started because one or more prerequisites are unresolved.%'
     OR v_update NOT LIKE '%Use complete_task() or cancel_task() to close a task%'
     OR v_update NOT LIKE '%INSERT INTO audit_logs%''edited''%''task''%' THEN
    v_missing := v_missing || 'start-enforcement-preservation ';
  END IF;

  IF v_complete NOT LIKE '%valid_task_status_transition(v_task.status, ''completed'')%'
     OR v_complete NOT LIKE '%pg_advisory_xact_lock%task_dependencies:%'
     OR v_complete NOT LIKE '%FOR UPDATE%'
     OR v_complete NOT LIKE '%get_task_dependency_state(p_task_id)%'
     OR v_complete NOT LIKE '%Task cannot be completed because one or more prerequisites are unresolved.%'
     OR v_complete NOT LIKE '%INSERT INTO audit_logs%''completed''%''task''%'
     OR v_complete NOT LIKE '%INSERT INTO notifications%''task_completed''%' THEN
    v_missing := v_missing || 'complete-enforcement-preservation ';
  END IF;

  IF v_cancel LIKE '%task_dependenc%'
     OR v_cancel NOT LIKE '%UPDATE tasks SET status = ''cancelled''%'
     OR v_cancel NOT LIKE '%''cancelled'', ''task''%' THEN
    v_missing := v_missing || 'cancel-unaffected ';
  END IF;

  IF v_state NOT LIKE '%can_view_task(p_task_id)%'
     OR v_state NOT LIKE '%get_task_dependency_state(p_task_id)%'
     OR v_state NOT LIKE '%can_view_task(td.dependent_task_id)%'
     OR v_state NOT LIKE '%can_view_task(td.prerequisite_task_id)%'
     OR v_state NOT LIKE '%ELSE NULL::BIGINT%'
     OR v_state LIKE '%task_number%'
     OR v_state LIKE '%title%' THEN
    v_missing := v_missing || 'state-fail-closed-no-details ';
  END IF;

  IF NOT has_function_privilege('authenticated','update_task(uuid,text,text,text,text,date,date,uuid,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','complete_task(uuid,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','create_task_dependency(uuid,uuid)','EXECUTE')
     OR NOT has_function_privilege('authenticated','get_task_dependency_lifecycle_state(uuid)','EXECUTE')
     OR has_function_privilege('anon','get_task_dependency_lifecycle_state(uuid)','EXECUTE') THEN
    v_missing := v_missing || 'function-grants ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='tasks'
      AND column_name IN ('blocked','is_blocked','blocked_at','dependency_status')
  ) OR (SELECT pg_get_constraintdef(oid) LIKE '%''blocked''%'
        FROM pg_constraint WHERE conname='tasks_status_check') THEN
    v_missing := v_missing || 'stored-blocked-state ';
  END IF;

  IF to_regclass('public.task_dependencies') IS NULL
     OR to_regclass('public.task_dependency_waivers') IS NULL
     OR to_regprocedure('public.create_task_dependency(uuid,uuid)') IS NULL
     OR to_regprocedure('public.remove_task_dependency(uuid)') IS NULL
     OR to_regprocedure('public.list_task_dependencies(uuid,integer,integer)') IS NULL
     OR to_regprocedure('public.get_task_dependency_capabilities(uuid)') IS NULL
     OR to_regclass('public.task_relationships') IS NULL
     OR to_regprocedure('public.create_task_relationship(uuid,uuid,text)') IS NULL
     OR to_regclass('public.task_links') IS NULL
     OR to_regclass('public.attachments') IS NULL
     OR to_regclass('public.task_comments') IS NULL
     OR to_regclass('public.task_assignments') IS NULL
     OR to_regclass('public.task_watchers') IS NULL THEN
    v_missing := v_missing || 'foundation-regression ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task Dependency Lifecycle validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Task Dependency Lifecycle validation PASSED';
END $$;
