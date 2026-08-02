-- CAP-002 Phase 2 workflow runtime structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_signature TEXT;
  v_definition TEXT;
  v_status_constraint TEXT;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'workflow_transition_instance(uuid,text,bigint,uuid,text,text)',
    'start_workflow_instance(uuid,bigint,uuid)',
    'suspend_workflow_instance(uuid,bigint,uuid,text)',
    'resume_workflow_instance(uuid,bigint,uuid,text)',
    'cancel_workflow_instance(uuid,bigint,uuid,text)',
    'complete_workflow_instance(uuid,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure('public.' || v_signature) IS NULL THEN
      v_missing := v_missing || v_signature || ' ';
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid=to_regprocedure('public.'||v_signature))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid=to_regprocedure('public.'||v_signature)
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN
      v_missing := v_missing || v_signature || '-security ';
    END IF;
  END LOOP;

  IF has_function_privilege('authenticated','workflow_transition_instance(uuid,text,bigint,uuid,text,text)','EXECUTE')
     OR has_function_privilege('anon','workflow_transition_instance(uuid,text,bigint,uuid,text,text)','EXECUTE')
     OR has_function_privilege('public','workflow_transition_instance(uuid,text,bigint,uuid,text,text)','EXECUTE') THEN
    v_missing := v_missing || 'internal-transition-exposure ';
  END IF;

  FOREACH v_signature IN ARRAY ARRAY[
    'start_workflow_instance(uuid,bigint,uuid)',
    'suspend_workflow_instance(uuid,bigint,uuid,text)',
    'resume_workflow_instance(uuid,bigint,uuid,text)',
    'cancel_workflow_instance(uuid,bigint,uuid,text)',
    'complete_workflow_instance(uuid,bigint,uuid,text)'
  ] LOOP
    IF NOT has_function_privilege('authenticated',v_signature,'EXECUTE')
       OR has_function_privilege('anon',v_signature,'EXECUTE')
       OR has_function_privilege('public',v_signature,'EXECUTE') THEN
      v_missing := v_missing || v_signature || '-grant ';
    END IF;
  END LOOP;

  SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure)
  INTO v_definition;
  IF v_definition NOT ILIKE '%can_manage_workflow_instance%'
     OR v_definition NOT ILIKE '%FOR UPDATE%'
     OR v_definition NOT ILIKE '%pg_advisory_xact_lock%'
     OR v_definition NOT ILIKE '%lock_version <> p_expected_lock_version%'
     OR v_definition NOT ILIKE '%idempotency_key = p_idempotency_key%'
     OR v_definition NOT ILIKE '%next_event_sequence = next_event_sequence + 1%'
     OR v_definition NOT ILIKE '%INSERT INTO workflow_events%'
     OR v_definition NOT ILIKE '%workflow instance cannot complete while runtime work remains open%'
  THEN v_missing := v_missing || 'transition-contract '; END IF;

  IF v_definition ILIKE '%requests%'
     OR v_definition ILIKE '%external_correspondence%'
     OR v_definition ILIKE '%internal_requests%'
     OR v_definition ILIKE '%prisoner_letters%'
     OR v_definition ILIKE '%meetings%'
     OR v_definition ILIKE '%tasks%'
     OR v_definition ILIKE '%notifications%'
     OR v_definition ILIKE '%audit_logs%'
     OR v_definition ILIKE '%pg_cron%'
  THEN v_missing := v_missing || 'forbidden-integration '; END IF;

  IF to_regprocedure('reopen_workflow_instance(uuid,bigint,uuid,text)') IS NOT NULL
     OR to_regprocedure('reject_workflow_instance(uuid,bigint,uuid,text)') IS NOT NULL
     OR to_regprocedure('withdraw_workflow_instance(uuid,bigint,uuid,text)') IS NOT NULL
     OR to_regprocedure('approve_workflow_item(uuid,bigint,uuid,text)') IS NOT NULL
     OR to_regprocedure('route_workflow_instance(uuid,uuid,bigint,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-rpc '; END IF;

  SELECT pg_get_constraintdef(oid) INTO v_status_constraint
  FROM pg_constraint
  WHERE conrelid='workflow_instances'::regclass
    AND conname='workflow_instances_status_check';
  IF v_status_constraint IS NULL
     OR v_status_constraint NOT ILIKE '%pending%active%suspended%completed%rejected%cancelled%withdrawn%failed%'
  THEN v_missing := v_missing || 'architecture-state-model '; END IF;

  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='workflow_instances')<>19
     OR (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='workflow_events')<>12
  THEN v_missing := v_missing || 'foundation-column-drift '; END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='workflow_instances'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='workflow_events'::regclass)
     OR (SELECT count(*) FROM pg_policy WHERE polrelid='workflow_instances'::regclass AND polcmd='r')<>1
     OR (SELECT count(*) FROM pg_policy WHERE polrelid='workflow_events'::regclass AND polcmd='r')<>1
     OR EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid IN ('workflow_instances'::regclass,'workflow_events'::regclass)
         AND polcmd<>'r'
     ) THEN v_missing := v_missing || 'rls-drift '; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public'
      AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated')
      AND privilege_type<>'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='workflow_events'::regclass
      AND tgname='workflow_events_immutable' AND NOT tgisinternal
  ) THEN v_missing := v_missing || 'event-immutability '; END IF;

  IF to_regclass('workflow_definitions') IS NULL
     OR to_regclass('workflow_definition_versions') IS NULL
     OR to_regclass('workflow_instance_steps') IS NULL
     OR to_regclass('workflow_tokens') IS NULL
     OR to_regclass('workflow_work_items') IS NULL
     OR to_regclass('workflow_participants') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
     OR to_regclass('workflow_variables') IS NULL
     OR to_regprocedure('create_workflow_instance(uuid,text,uuid,uuid,uuid,uuid)') IS NULL
     OR to_regprocedure('get_workflow_instance(uuid)') IS NULL
  THEN v_missing := v_missing || 'phase1-foundation '; END IF;

  IF v_missing<>'' THEN
    RAISE EXCEPTION 'Workflow runtime validation FAILED: %',v_missing;
  END IF;
  RAISE NOTICE 'Workflow runtime validation PASSED (6 functions, 5 RPCs, legal states, locking/idempotency/event contract, unchanged SELECT-only RLS, no integrations).';
END $$;
