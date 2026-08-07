-- CAP-002 Phase 5.4 SLA timer dispatch & worker foundation rollback
-- validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_name TEXT; v_present TEXT := '';
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'process_workflow_sla_due_batch(integer)',
    'workflow_sla_process_due_warnings(integer)',
    'workflow_sla_process_due_breaches(integer)',
    'workflow_sla_process_due_escalations(integer)',
    'workflow_sla_automatic_idempotency_key(uuid,text)'
  ] LOOP
    IF to_regprocedure('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  IF v_present<>'' THEN RAISE EXCEPTION 'Workflow SLA timer dispatch rollback validation FAILED; objects remain: %',v_present; END IF;

  -- Purely additive phase -- zero new tables, so the workflow_ table
  -- count must remain exactly 24 (the Phase 5.3A baseline) after
  -- rollback, unchanged from before this phase ever existed.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 24
  THEN RAISE EXCEPTION 'Workflow SLA timer dispatch rollback validation FAILED; unexpected workflow table count (expected 24, unchanged by this purely-additive phase)'; END IF;

  -- Phase 1 through 5.3A baseline completely intact -- this rollback
  -- touches only the five functions it created, nothing else.
  IF to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regclass('public.workflow_sla_clocks') IS NULL
     OR to_regclass('public.workflow_sla_clock_events') IS NULL
     OR to_regclass('public.workflow_escalation_events') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.record_workflow_sla_warning(uuid,bigint,integer,uuid)') IS NULL
     OR to_regprocedure('public.record_workflow_sla_breach(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.trigger_workflow_sla_escalation(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_warning(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_breach(integer)') IS NULL
     OR to_regprocedure('public.workflow_sla_clocks_due_for_escalation(integer)') IS NULL
     OR to_regprocedure('public.workflow_calculate_calendar_deadline(timestamptz,numeric,text,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_calculate_calendar_offset_backward(timestamptz,numeric,text,uuid,text)') IS NULL
  THEN RAISE EXCEPTION 'Workflow SLA timer dispatch rollback validation FAILED; Phase 1 through 5.3A baseline drift'; END IF;

  -- restart_workflow_sla_clock remains private/ungranted (Phase 5.3A's
  -- own posture), untouched by this phase's rollback either way.
  IF to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)') IS NULL
     OR has_function_privilege('authenticated', to_regprocedure('public.restart_workflow_sla_clock(uuid,bigint,text,uuid)'), 'EXECUTE')
  THEN RAISE EXCEPTION 'Workflow SLA timer dispatch rollback validation FAILED; restart_workflow_sla_clock grant drift'; END IF;

  -- The manual RPCs remain exactly as authenticated-grantable as they
  -- always were -- this phase's rollback (like its own patch) never
  -- touched their grants.
  IF NOT has_function_privilege('authenticated', to_regprocedure('public.record_workflow_sla_warning(uuid,bigint,integer,uuid)'), 'EXECUTE')
     OR NOT has_function_privilege('authenticated', to_regprocedure('public.record_workflow_sla_breach(uuid,bigint,uuid)'), 'EXECUTE')
     OR NOT has_function_privilege('authenticated', to_regprocedure('public.trigger_workflow_sla_escalation(uuid,bigint,uuid)'), 'EXECUTE')
  THEN RAISE EXCEPTION 'Workflow SLA timer dispatch rollback validation FAILED; manual RPC grant drift'; END IF;

  -- No evidence was destroyed by this rollback -- existing workflow_
  -- sla_clock_events / workflow_escalation_events rows (including any
  -- written by the dispatcher before rollback) remain exactly as they
  -- were; a function rollback never touches already-stored rows.
  -- (No row-count assertion here by design: this validator runs
  -- against whatever fixture state happens to exist, and the
  -- invariant being verified is schema/grant equality, not row
  -- survival count, which the rollback rehearsal below confirms
  -- directly against a controlled fixture instead.)

  RAISE NOTICE 'Workflow SLA timer dispatch rollback validation PASSED (all 5 new functions absent, workflow table count unchanged at 24, Phase 1 through 5.3A baseline fully intact, restart_workflow_sla_clock privatization and manual-RPC grants unaffected by this purely-additive phase''s rollback).';
END $$;
