-- CAP-002 Phase 5.3 SLA & escalation foundation rollback.
--
-- Refuses to discard any SLA/escalation data -- no CASCADE is used.
-- Mirrors the Phase 5.1 (rollback-workflow-delegation-substitution-
-- foundation.sql) "refuse if any row exists" precedent exactly, not
-- the "protect real activated work" precedent used elsewhere in this
-- engine -- because every one of the 8 tables this milestone creates
-- is wholly new (no prior data was ever possible), so any row that
-- exists at rollback time is necessarily real, created work
-- (including administrative configuration -- a published business
-- calendar version or an escalation policy is itself immutable
-- business evidence once created, not merely draft state) that a
-- permissive rollback would silently destroy.
--
-- Drops every object this patch created: all 8 tables, every public
-- RPC, and every private helper/trigger function. Restores nothing
-- (no pre-5.3 body to restore -- every one of these objects is
-- wholly new). Phase 1 through 5.2's entire baseline, including the
-- workflow_instances.execution_epoch column (pre-existing since
-- Phase 1, never altered by this patch), is completely untouched.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_table TEXT; v_count BIGINT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'workflow_escalation_events','workflow_sla_clock_events','workflow_sla_clocks',
    'workflow_sla_policies','workflow_escalation_levels','workflow_escalation_policies',
    'workflow_business_calendar_versions','workflow_business_calendars'
  ] LOOP
    IF to_regclass('public.'||v_table) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I',v_table) INTO v_count;
      IF v_count<>0 THEN
        RAISE EXCEPTION 'Workflow SLA/escalation foundation rollback refused: % contains % row(s) -- this would silently destroy real SLA/escalation evidence or configuration',v_table,v_count;
      END IF;
    END IF;
  END LOOP;
END $$;

-- Tables first, in FK-safe order (children before parents). Dropping
-- a table implicitly drops its own RLS policies, which is required
-- before the authorization-helper functions those policies reference
-- (can_manage_workflow_sla_config) can themselves be dropped below.
-- The calendars<->versions FK cycle requires dropping the calendars-
-- side constraint before either table can be dropped.
DROP TABLE IF EXISTS workflow_escalation_events;
DROP TABLE IF EXISTS workflow_sla_clock_events;
DROP TABLE IF EXISTS workflow_sla_clocks;
DROP TABLE IF EXISTS workflow_sla_policies;
DROP TABLE IF EXISTS workflow_escalation_levels;
DROP TABLE IF EXISTS workflow_escalation_policies;
ALTER TABLE IF EXISTS workflow_business_calendars DROP CONSTRAINT IF EXISTS workflow_business_calendars_active_version_fkey;
DROP TABLE IF EXISTS workflow_business_calendar_versions;
DROP TABLE IF EXISTS workflow_business_calendars;

-- Public lifecycle/config RPCs.
DROP FUNCTION IF EXISTS trigger_workflow_sla_escalation(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS record_workflow_sla_breach(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS record_workflow_sla_warning(UUID,BIGINT,INTEGER,UUID);
DROP FUNCTION IF EXISTS cancel_workflow_sla_clock(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS complete_workflow_sla_clock(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS restart_workflow_sla_clock(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS resume_workflow_sla_clock(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS pause_workflow_sla_clock(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS create_workflow_sla_clock(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID);
DROP FUNCTION IF EXISTS create_workflow_sla_policy(UUID,TEXT,TEXT,NUMERIC,TEXT,UUID,TEXT,JSONB,BOOLEAN,BOOLEAN,UUID,UUID);
DROP FUNCTION IF EXISTS create_workflow_escalation_policy(UUID,TEXT,TEXT,JSONB,UUID);
DROP FUNCTION IF EXISTS create_workflow_business_calendar_version(UUID,TEXT,TEXT,TEXT,INTEGER[],TIME,TIME,DATE[],UUID);

-- Private due-detection foundation + calendar/offset arithmetic.
DROP FUNCTION IF EXISTS workflow_sla_clocks_due_for_escalation(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_clocks_due_for_breach(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_clocks_due_for_warning(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_offset_interval(NUMERIC,TEXT);
DROP FUNCTION IF EXISTS workflow_calculate_calendar_deadline(TIMESTAMPTZ,NUMERIC,TEXT,UUID,TEXT);

-- Private authorization helpers.
DROP FUNCTION IF EXISTS can_manage_workflow_sla_clock(UUID);
DROP FUNCTION IF EXISTS can_manage_workflow_sla_config(UUID);

-- Trigger functions (all private to this patch; workflow_reject_
-- evidence_mutation is reused across workflow_sla_clock_events and
-- workflow_escalation_events, both dropped above, so it too is
-- exclusively owned by this patch and safe to drop).
DROP FUNCTION IF EXISTS workflow_reject_terminal_sla_clock_mutation();
DROP FUNCTION IF EXISTS workflow_reject_evidence_mutation();
DROP FUNCTION IF EXISTS workflow_reject_escalation_config_mutation();
DROP FUNCTION IF EXISTS workflow_reject_calendar_version_mutation();

COMMIT;
