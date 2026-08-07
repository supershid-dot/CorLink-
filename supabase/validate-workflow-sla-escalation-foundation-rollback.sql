-- CAP-002 Phase 5.3 SLA & escalation foundation rollback validator
-- (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_name TEXT; v_present TEXT := '';
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'workflow_business_calendars','workflow_business_calendar_versions',
    'workflow_escalation_policies','workflow_escalation_levels',
    'workflow_sla_policies','workflow_sla_clocks',
    'workflow_sla_clock_events','workflow_escalation_events'
  ] LOOP
    IF to_regclass('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  FOREACH v_name IN ARRAY ARRAY[
    'create_workflow_business_calendar_version(uuid,text,text,text,integer[],time,time,date[],uuid)',
    'create_workflow_escalation_policy(uuid,text,text,jsonb,uuid)',
    'create_workflow_sla_policy(uuid,text,text,numeric,text,uuid,text,jsonb,boolean,boolean,uuid,uuid)',
    'create_workflow_sla_clock(uuid,uuid,uuid,uuid,text,uuid,timestamptz,text,uuid)',
    'pause_workflow_sla_clock(uuid,bigint,text,uuid)',
    'resume_workflow_sla_clock(uuid,bigint,uuid)',
    'restart_workflow_sla_clock(uuid,bigint,text,uuid)',
    'complete_workflow_sla_clock(uuid,bigint,uuid)',
    'cancel_workflow_sla_clock(uuid,bigint,text,uuid)',
    'record_workflow_sla_warning(uuid,bigint,integer,uuid)',
    'record_workflow_sla_breach(uuid,bigint,uuid)',
    'trigger_workflow_sla_escalation(uuid,bigint,uuid)',
    'workflow_calculate_calendar_deadline(timestamptz,numeric,text,uuid,text)',
    'workflow_sla_offset_interval(numeric,text)',
    'workflow_sla_clocks_due_for_warning(integer)',
    'workflow_sla_clocks_due_for_breach(integer)',
    'workflow_sla_clocks_due_for_escalation(integer)',
    'can_manage_workflow_sla_config(uuid)',
    'can_manage_workflow_sla_clock(uuid)',
    'workflow_reject_calendar_version_mutation()',
    'workflow_reject_escalation_config_mutation()',
    'workflow_reject_terminal_sla_clock_mutation()',
    'workflow_reject_evidence_mutation()'
  ] LOOP
    IF to_regprocedure('public.'||v_name) IS NOT NULL THEN v_present:=v_present||v_name||' '; END IF;
  END LOOP;
  IF v_present<>'' THEN RAISE EXCEPTION 'Workflow SLA/escalation foundation rollback validation FAILED; objects remain: %',v_present; END IF;

  -- Phase 1 through 5.2 baseline intact -- this rollback touches only
  -- the objects it created; execution_epoch (pre-existing since
  -- Phase 1) is untouched, and every Phase 5.1/5.2 delegation/
  -- substitution object remains exactly as it was.
  IF to_regclass('public.workflow_definitions') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regclass('public.workflow_approval_rounds') IS NULL
     OR to_regclass('public.workflow_delegations') IS NULL
     OR to_regclass('public.workflow_substitutions') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.workflow_resolve_active_delegation(uuid,uuid,uuid,uuid,uuid,text,text,uuid,uuid,timestamptz)') IS NULL
     OR to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_evaluate_gateway_condition(uuid,jsonb)') IS NULL
  THEN RAISE EXCEPTION 'Workflow SLA/escalation foundation rollback validation FAILED; Phase 1 through 5.2 baseline drift'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='workflow_instances' AND column_name='execution_epoch'
  ) THEN RAISE EXCEPTION 'Workflow SLA/escalation foundation rollback validation FAILED; workflow_instances.execution_epoch unexpectedly missing'; END IF;

  -- Back to exactly 16 workflow_ tables (the Phase 1-through-5.2
  -- baseline), all 8 of this phase's tables gone.
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16
  THEN RAISE EXCEPTION 'Workflow SLA/escalation foundation rollback validation FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow SLA/escalation foundation rollback validation PASSED (all 8 new tables and every RPC/helper/trigger absent, Phase 1 through 5.2 baseline fully intact, workflow table count back to 16).';
END $$;
