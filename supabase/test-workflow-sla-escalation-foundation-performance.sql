-- CAP-002 Phase 5.3 SLA & escalation foundation performance probes.
-- Disposable local PostgreSQL only. Scale: ~10,000 active clocks,
-- ~10,000 completed/cancelled clocks (large history), multiple
-- escalation levels, a realistic business calendar (holidays across
-- a full year), and 100,000 workflow_sla_clock_events rows.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('65360000-0000-0000-0000-000000000001','WF53P Org','authority','WF53P');
INSERT INTO auth.users(id,email) VALUES
 ('65360000-0001-0000-0000-000000000001','admin@wf53p.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65360000-0001-0000-0000-000000000001','65360000-0000-0000-0000-000000000001','WF53P-1','Admin','admin@wf53p.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65360000-0001-0000-0000-000000000001','organization','65360000-0000-0000-0000-000000000001','authority_admin',true,true);

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65360000-0001-0000-0000-000000000001"}',false);

WITH made AS (SELECT * FROM create_workflow_definition(
  '65360000-0000-0000-0000-000000000001','wf53p_org','WF53P Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf53p_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf53p_def),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT v FROM wf53p_def),'opaque_case',gen_random_uuid(),
  '65360000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
SELECT create_workflow_instance AS id INTO TEMP wf53p_i1 FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf53p_i1),0,gen_random_uuid());

RESET ROLE;

-- A realistic business calendar: Mon-Fri, 09:00-17:00, with holidays
-- spread across a full year (26 -- roughly a real organization's
-- count of public holidays + a few extra observances).
DO $$
DECLARE v_holidays DATE[];
BEGIN
  SELECT array_agg('2026-01-01'::DATE + (i * 14)) INTO v_holidays FROM generate_series(0,25) i;
  INSERT INTO workflow_business_calendars (id, organization_id, calendar_key, name, created_by)
  VALUES ('65360000-0003-0000-0000-000000000001', '65360000-0000-0000-0000-000000000001', 'wf53p_cal', 'WF53P Calendar', '65360000-0001-0000-0000-000000000001');
  INSERT INTO workflow_business_calendar_versions (id, calendar_id, version_number, timezone, working_days, working_hours_start, working_hours_end, holidays, content_hash, created_by)
  VALUES ('65360000-0003-0000-0000-000000000002', '65360000-0003-0000-0000-000000000001', 1, 'UTC', ARRAY[1,2,3,4,5], '09:00', '17:00', v_holidays, 'perf-fixture', '65360000-0001-0000-0000-000000000001');
  UPDATE workflow_business_calendars SET active_version_id = '65360000-0003-0000-0000-000000000002' WHERE id = '65360000-0003-0000-0000-000000000001';
END $$;

-- A multi-level escalation policy (4 levels) + an SLA policy referencing it.
INSERT INTO workflow_escalation_policies (id, organization_id, policy_key, name, created_by)
VALUES ('65360000-0004-0000-0000-000000000001', '65360000-0000-0000-0000-000000000001', 'wf53p_esc', 'WF53P Escalation Policy', '65360000-0001-0000-0000-000000000001');
INSERT INTO workflow_escalation_levels (escalation_policy_id, level_order, offset_from, offset_amount, offset_unit, action_code, created_by)
VALUES
 ('65360000-0004-0000-0000-000000000001', 1, 'breach', 0, 'hours', 'remind_actor', '65360000-0001-0000-0000-000000000001'),
 ('65360000-0004-0000-0000-000000000001', 2, 'previous_level', 1, 'hours', 'notify_supervisor', '65360000-0001-0000-0000-000000000001'),
 ('65360000-0004-0000-0000-000000000001', 3, 'previous_level', 2, 'hours', 'route_higher_scope', '65360000-0001-0000-0000-000000000001'),
 ('65360000-0004-0000-0000-000000000001', 4, 'previous_level', 4, 'hours', 'mark_breached', '65360000-0001-0000-0000-000000000001');
INSERT INTO workflow_sla_policies (id, organization_id, policy_key, name, duration_amount, duration_unit, timezone, pause_eligible, restart_eligible, escalation_policy_id, created_by)
VALUES ('65360000-0005-0000-0000-000000000001', '65360000-0000-0000-0000-000000000001', 'wf53p_policy', 'WF53P SLA Policy', 4, 'hours', 'UTC', true, true, '65360000-0004-0000-0000-000000000001', '65360000-0001-0000-0000-000000000001');

-- ── Bulk fixture: 10,000 active (running) clocks, roughly half
--    already past their deadline (candidates for the due-detection
--    queries), half still in the future -- plus 2,000 of them
--    carrying the multi-level escalation policy at varying levels. ──
INSERT INTO workflow_sla_clocks (
  id, instance_id, organization_id, deadline_rule_type, start_event_type, started_at,
  timezone, effective_deadline, effective_deadline_adjusted, escalation_policy_id,
  current_escalation_level, state, pause_eligible, restart_eligible, created_by
)
SELECT
  gen_random_uuid(), (SELECT id FROM wf53p_i1), '65360000-0000-0000-0000-000000000001', 'absolute', 'manual',
  now() - interval '1 hour',
  'UTC',
  now() + ((i % 1000) - 500) * interval '1 minute',
  now() + ((i % 1000) - 500) * interval '1 minute',
  CASE WHEN i <= 2000 THEN '65360000-0004-0000-0000-000000000001'::UUID ELSE NULL END,
  CASE WHEN i <= 2000 THEN i % 4 ELSE 0 END,
  'running', true, true, '65360000-0001-0000-0000-000000000001'
FROM generate_series(1, 10000) i;

-- ── Bulk fixture: 10,000 completed/cancelled clocks (large historical
--    tail every history-scanning query must filter past). ──────────
INSERT INTO workflow_sla_clocks (
  id, instance_id, organization_id, deadline_rule_type, start_event_type, started_at,
  timezone, effective_deadline, effective_deadline_adjusted,
  state, completed_at, cancelled_at, pause_eligible, restart_eligible, created_by
)
SELECT
  gen_random_uuid(), (SELECT id FROM wf53p_i1), '65360000-0000-0000-0000-000000000001', 'absolute', 'manual',
  now() - interval '30 days',
  'UTC',
  now() - interval '29 days',
  now() - interval '29 days',
  CASE WHEN i % 2 = 0 THEN 'completed' ELSE 'cancelled' END,
  CASE WHEN i % 2 = 0 THEN now() - interval '29 days' ELSE NULL END,
  CASE WHEN i % 2 = 0 THEN NULL ELSE now() - interval '29 days' END,
  false, false, '65360000-0001-0000-0000-000000000001'
FROM generate_series(1, 10000) i;

-- ── 100,000 evidence events distributed across all 20,000 clocks
--    (5 each) -- synthetic bulk history for scale, not a real replay-
--    valid sequence (mirrors the established "mostly-irrelevant bulk
--    fixture" pattern from the Phase 5.1/5.2 performance suites). ──
INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, idempotency_key)
SELECT c.id, c.instance_id, 'started', gen_random_uuid()
FROM workflow_sla_clocks c CROSS JOIN generate_series(1,5) g;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65360000-0001-0000-0000-000000000001"}',false);

-- ── Dimension 1: create_workflow_sla_clock amid 20,000 existing
--    clocks and 100,000 events ─────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_id UUID;
BEGIN
  v_start := clock_timestamp();
  SELECT clock_id INTO v_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53p_i1), NULL, NULL, '65360000-0005-0000-0000-000000000001', 'manual', NULL, NULL, NULL, gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (create_workflow_sla_clock, amid 20,000 clocks / 100,000 events): % ms', round(v_ms, 2);
  CREATE TEMP TABLE wf53p_probe1 AS SELECT v_id AS id;
END $$;

-- ── Dimension 2: pause + resume cycle ───────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_id UUID := (SELECT id FROM wf53p_probe1);
BEGIN
  v_start := clock_timestamp();
  PERFORM pause_workflow_sla_clock(v_id, 0, 'perf probe', gen_random_uuid());
  PERFORM resume_workflow_sla_clock(v_id, 1, gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (pause + resume cycle): % ms', round(v_ms, 2);
END $$;

-- ── Dimension 3: record_workflow_sla_warning on an already-due offset ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_id UUID; v_policy_id UUID;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65360000-0000-0000-0000-000000000001','wf53p_policy_warn','WF53P warning policy',
    2,'hours',NULL,'UTC','[{"amount":3,"unit":"hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  SELECT clock_id INTO v_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53p_i1), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  v_start := clock_timestamp();
  PERFORM record_workflow_sla_warning(v_id, 0, 0, gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 3 (record_workflow_sla_warning): % ms', round(v_ms, 2);
END $$;

-- ── Dimension 4: record_workflow_sla_breach on an already-elapsed deadline ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_id UUID;
BEGIN
  SELECT clock_id INTO v_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53p_i1), NULL, NULL, NULL, 'manual', NULL, now() - interval '1 hour', 'UTC', gen_random_uuid());
  v_start := clock_timestamp();
  PERFORM record_workflow_sla_breach(v_id, 0, gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4 (record_workflow_sla_breach): % ms', round(v_ms, 2);
END $$;

-- ── Dimension 5: trigger_workflow_sla_escalation (manual escalation) ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_id UUID;
BEGIN
  SELECT clock_id INTO v_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53p_i1), NULL, NULL, '65360000-0005-0000-0000-000000000001', 'manual', NULL, NULL, NULL, gen_random_uuid());
  v_start := clock_timestamp();
  PERFORM trigger_workflow_sla_escalation(v_id, 0, gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 5 (trigger_workflow_sla_escalation, 4-level policy): % ms', round(v_ms, 2);
END $$;

RESET ROLE;

-- ── Dimension 6: the three due-detection helpers at 10,000-active-
--    clock scale, timed and index-usage-confirmed via EXPLAIN
--    (ANALYZE, BUFFERS). These are the deterministic "what's due"
--    queries a future dispatcher would wrap in SKIP LOCKED batches --
--    never executed on a schedule by this patch itself. ────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_sla_clocks_due_for_breach(1000);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6a (workflow_sla_clocks_due_for_breach, limit 1000, at 10,000 active clocks): % ms, % candidates', round(v_ms, 2), v_count;

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_sla_clocks_due_for_warning(1000);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6b (workflow_sla_clocks_due_for_warning, limit 1000): % ms, % candidates', round(v_ms, 2), v_count;

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_sla_clocks_due_for_escalation(1000);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6c (workflow_sla_clocks_due_for_escalation, limit 1000, 2,000 escalation-bearing clocks): % ms, % candidates', round(v_ms, 2), v_count;
END $$;

-- Confirm the breach-due query uses the partial index
-- (idx_workflow_sla_clocks_breach_due), never a sequential scan,
-- at this scale.
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  v_plan := '';
  FOR v_line IN EXECUTE $q$EXPLAIN (FORMAT TEXT)
    SELECT * FROM workflow_sla_clocks WHERE state = 'running' AND breached_at IS NULL
      AND effective_deadline_adjusted <= clock_timestamp() ORDER BY effective_deadline_adjusted LIMIT 1000$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on workflow_sla_clocks%' THEN
    RAISE EXCEPTION 'expected the breach-due access path to use idx_workflow_sla_clocks_breach_due, got a sequential scan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 6d (index usage): the breach-due access path (state=running AND breached_at IS NULL, ordered by effective_deadline_adjusted) uses an index at 20,000-row scale, never a sequential scan';
END $$;

-- Confirm the calendar-aware deadline calculation itself remains fast
-- against a calendar with a full year's worth of holidays.
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_deadline TIMESTAMPTZ;
BEGIN
  v_start := clock_timestamp();
  v_deadline := workflow_calculate_calendar_deadline(now(), 3, 'business_days', '65360000-0003-0000-0000-000000000002', 'UTC');
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6e (workflow_calculate_calendar_deadline, business_days, 26-holiday calendar): % ms', round(v_ms, 2);
END $$;

-- ── CAP-002 Phase 5.3A correction 2 performance dimensions:
--    calendar-aware business-time offset evaluation. ────────────────

-- Dimension 6f: a single backward business-hours offset call, normal
-- working-week calculation (no holidays crossed).
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_result TIMESTAMPTZ;
BEGIN
  v_start := clock_timestamp();
  v_result := workflow_calculate_calendar_offset_backward(now(), 2, 'business_hours', '65360000-0003-0000-0000-000000000002', 'UTC');
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6f (workflow_calculate_calendar_offset_backward, business_hours, normal working week): % ms', round(v_ms, 2);
END $$;

-- Dimension 6g: a backward business_days offset against the 26-
-- holiday-heavy calendar (the holiday-density case that most
-- stresses the bounded day-stepping loop).
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_result TIMESTAMPTZ;
BEGIN
  v_start := clock_timestamp();
  v_result := workflow_calculate_calendar_offset_backward(now(), 10, 'business_days', '65360000-0003-0000-0000-000000000002', 'UTC');
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6g (workflow_calculate_calendar_offset_backward, business_days, holiday-heavy 26-holiday calendar): % ms', round(v_ms, 2);
END $$;

-- Dimension 6h: repeated business-hour walking -- 1,000 consecutive
-- backward calls, simulating a batch of warning-offset evaluations.
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_result TIMESTAMPTZ; i INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR i IN 1..1000 LOOP
    v_result := workflow_calculate_calendar_offset_backward(now() - (i || ' minutes')::INTERVAL, 3, 'business_hours', '65360000-0003-0000-0000-000000000002', 'UTC');
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6h (1,000 repeated workflow_calculate_calendar_offset_backward calls, business_hours): % ms total, % ms/call', round(v_ms, 2), round(v_ms / 1000, 4);
END $$;

DO $$ BEGIN RAISE NOTICE 'Workflow SLA/escalation foundation performance probe PASSED'; END $$;
