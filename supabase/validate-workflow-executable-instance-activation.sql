-- CAP-002 Phase 2B.2 executable instance activation structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- New round/position tables: exist, RLS enabled, exactly one
  -- SELECT-only policy, no direct write grant.
  FOREACH v_def IN ARRAY ARRAY['workflow_approval_rounds','workflow_approval_positions'] LOOP
    IF to_regclass('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || ' ';
    ELSIF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || v_def)) THEN
      v_missing := v_missing || v_def || '-rls ';
    ELSIF (SELECT count(*) FROM pg_policy WHERE polrelid = to_regclass('public.' || v_def) AND polcmd = 'r') <> 1
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = to_regclass('public.' || v_def) AND polcmd <> 'r') THEN
      v_missing := v_missing || v_def || '-select-only-policy ';
    END IF;
  END LOOP;

  -- CAP-002 Phase 5.1 legitimately added 4 new tables
  -- (workflow_delegations, workflow_delegation_events,
  -- workflow_substitutions, workflow_substitution_events) on top of
  -- this milestone's own baseline of 12 -- this check is updated to
  -- the new, superseding total of 24 (Phase 5.1 brought it to 16,
  -- Phase 5.3 added 8 more), not defective.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 24
  THEN v_missing := v_missing || 'unexpected-workflow-table-count '; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated')
      AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- workflow_transition_instance signature unchanged, still pinned
  -- SECURITY DEFINER, still ungranted to authenticated/anon/PUBLIC;
  -- the five public wrapper RPCs unchanged and still the only grant.
  IF to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)') IS NULL THEN
    v_missing := v_missing || 'workflow_transition_instance-missing ';
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid = to_regprocedure('public.workflow_transition_instance(uuid,text,bigint,uuid,text,text)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN v_missing := v_missing || 'workflow_transition_instance-security '; END IF;
    IF has_function_privilege('authenticated', 'workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure, 'EXECUTE')
    THEN v_missing := v_missing || 'workflow_transition_instance-execute-leak '; END IF;
  END IF;

  FOREACH v_def IN ARRAY ARRAY[
    'start_workflow_instance(uuid,bigint,uuid)','suspend_workflow_instance(uuid,bigint,uuid,text)',
    'resume_workflow_instance(uuid,bigint,uuid,text)','cancel_workflow_instance(uuid,bigint,uuid,text)',
    'complete_workflow_instance(uuid,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSIF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_def), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || v_def || '-grant-drift ';
    END IF;
  END LOOP;

  -- Activation logic exists (in the shared transition function),
  -- reuses the Phase 2B.1 canonicalizer for integrity re-verification,
  -- pins the instance's own definition_version_id (never substitutes
  -- the family's active_version_id), enforces exactly-one-token, and
  -- explicitly stops after first-node entry (no advance_workflow,
  -- decide_workflow, or routing helpers exist).
  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%schema_version%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
     OR v_def NOT ILIKE '%v_instance.definition_version_id%'
     OR v_def ILIKE '%active_version_id%'
     OR v_def NOT ILIKE '%epoch_%token_1%'
     OR v_def NOT ILIKE '%workflow_approval_rounds%'
     OR v_def NOT ILIKE '%workflow_approval_positions%'
  THEN v_missing := v_missing || 'activation-logic-missing '; END IF;

  IF to_regprocedure('public.advance_workflow_instance(uuid)') IS NOT NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,uuid)') IS NOT NULL
     OR to_regprocedure('public.record_workflow_decision(uuid,text)') IS NOT NULL
     OR to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc-present '; END IF;

  -- Legacy inert 'start' path (no schema_version key) is untouched:
  -- the original single-event instance_started INSERT still exists
  -- verbatim as the fallback branch.
  IF v_def NOT ILIKE '%v_event_sequence := v_instance.next_event_sequence%'
     OR v_def NOT ILIKE '%jsonb_strip_nulls(jsonb_build_object(%'
  THEN v_missing := v_missing || 'legacy-start-path-missing '; END IF;

  -- Phase 2B.1 validator remains intact and untouched.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'phase-2b1-canonicalizer-missing ';
  ELSIF has_function_privilege('authenticated', 'canonicalize_workflow_definition_payload(jsonb,uuid)'::regprocedure, 'EXECUTE') THEN
    v_missing := v_missing || 'phase-2b1-canonicalizer-execute-leak ';
  END IF;
  IF to_regprocedure('public.create_workflow_definition(uuid,text,text,text,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.create_workflow_definition_version(uuid,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.publish_workflow_definition_version(uuid,bigint,uuid)') IS NULL
  THEN v_missing := v_missing || 'phase-2b1-rpcs-missing '; END IF;

  -- Baseline regression canary.
  IF to_regclass('public.requests') IS NULL OR to_regclass('public.tasks') IS NULL
     OR to_regclass('public.task_relationships') IS NULL OR to_regclass('public.task_links') IS NULL
     OR to_regclass('public.notifications') IS NULL OR to_regclass('public.audit_logs') IS NULL
     OR to_regclass('public.meetings') IS NULL
  THEN v_missing := v_missing || 'baseline-regression '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow executable instance activation validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow executable instance activation validation PASSED (2 new SELECT-only tables, activation logic present and pinned, legacy path intact, no out-of-scope RPCs, Phase 2B.1 validator intact, baseline objects present).';
END $$;
