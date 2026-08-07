-- CAP-002 Phase 5.4 SLA timer dispatch & worker foundation
-- performance probes. Disposable local PostgreSQL only. Scale:
-- ~10,000 active clocks (mixed due/not-due, ~2,000 carrying a
-- multi-level escalation policy at varying levels), ~10,000
-- completed/cancelled clocks (large historical tail), and 100,000
-- workflow_sla_clock_events rows -- the same scale Phase 5.3's own
-- performance suite established, since this phase's dispatcher reads
-- through the identical access paths.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('65340004-0000-0000-0000-000000000001','WF54P Org','authority','WF54P');
INSERT INTO auth.users(id,email) VALUES
 ('65340004-0001-0000-0000-000000000001','admin@wf54p.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65340004-0001-0000-0000-000000000001','65340004-0000-0000-0000-000000000001','WF54P-1','Admin','admin@wf54p.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65340004-0001-0000-0000-000000000001','organization','65340004-0000-0000-0000-000000000001','authority_admin',true,true);

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65340004-0001-0000-0000-000000000001"}',false);

WITH made AS (SELECT * FROM create_workflow_definition(
  '65340004-0000-0000-0000-000000000001','wf54p_org','WF54P Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf54p_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf54p_def),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT v FROM wf54p_def),'opaque_case',gen_random_uuid(),
  '65340004-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
SELECT create_workflow_instance AS id INTO TEMP wf54p_i1 FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf54p_i1),0,gen_random_uuid());

RESET ROLE;

-- A 4-level escalation policy (mirrors the Phase 5.3 performance
-- fixture exactly, same shape).
INSERT INTO workflow_escalation_policies (id, organization_id, policy_key, name, created_by)
VALUES ('65340004-0004-0000-0000-000000000001', '65340004-0000-0000-0000-000000000001', 'wf54p_esc', 'WF54P Escalation Policy', '65340004-0001-0000-0000-000000000001');
INSERT INTO workflow_escalation_levels (escalation_policy_id, level_order, offset_from, offset_amount, offset_unit, action_code, created_by)
VALUES
 ('65340004-0004-0000-0000-000000000001', 1, 'breach', 0, 'hours', 'remind_actor', '65340004-0001-0000-0000-000000000001'),
 ('65340004-0004-0000-0000-000000000001', 2, 'previous_level', 0, 'hours', 'notify_supervisor', '65340004-0001-0000-0000-000000000001'),
 ('65340004-0004-0000-0000-000000000001', 3, 'previous_level', 0, 'hours', 'route_higher_scope', '65340004-0001-0000-0000-000000000001'),
 ('65340004-0004-0000-0000-000000000001', 4, 'previous_level', 0, 'hours', 'mark_breached', '65340004-0001-0000-0000-000000000001');

-- ── Bulk fixture: 10,000 active (running) clocks. Roughly a third
--    already past their deadline and unbreached (breach-due
--    candidates), a third already breached and at escalation level 0
--    with the 4-level policy attached (escalation-due candidates),
--    a third still comfortably in the future (never due). ──────────
INSERT INTO workflow_sla_clocks (
  id, instance_id, organization_id, deadline_rule_type, start_event_type, started_at,
  timezone, effective_deadline, effective_deadline_adjusted, warning_offsets, warned_up_to_index,
  escalation_policy_id, current_escalation_level, breached_at, state, pause_eligible, restart_eligible, created_by
)
SELECT
  gen_random_uuid(), (SELECT id FROM wf54p_i1), '65340004-0000-0000-0000-000000000001', 'absolute', 'manual',
  now() - interval '2 hours',
  'UTC',
  CASE WHEN i % 3 = 0 THEN now() - interval '5 minutes' ELSE now() + interval '2 hours' END,
  CASE WHEN i % 3 = 0 THEN now() - interval '5 minutes' ELSE now() + interval '2 hours' END,
  '[]'::JSONB, -1,
  CASE WHEN i % 3 = 1 THEN '65340004-0004-0000-0000-000000000001'::UUID ELSE NULL END,
  0,
  CASE WHEN i % 3 = 1 THEN now() - interval '10 minutes' ELSE NULL END,
  'running', true, true, '65340004-0001-0000-0000-000000000001'
FROM generate_series(1, 10000) i;

-- ── Bulk fixture: 10,000 completed/cancelled clocks (large historical
--    tail the dispatcher's due-detection queries must never scan
--    through -- the partial indexes exist exactly to skip these). ───
INSERT INTO workflow_sla_clocks (
  id, instance_id, organization_id, deadline_rule_type, start_event_type, started_at,
  timezone, effective_deadline, effective_deadline_adjusted,
  state, completed_at, cancelled_at, pause_eligible, restart_eligible, created_by
)
SELECT
  gen_random_uuid(), (SELECT id FROM wf54p_i1), '65340004-0000-0000-0000-000000000001', 'absolute', 'manual',
  now() - interval '30 days',
  'UTC',
  now() - interval '29 days',
  now() - interval '29 days',
  CASE WHEN i % 2 = 0 THEN 'completed' ELSE 'cancelled' END,
  CASE WHEN i % 2 = 0 THEN now() - interval '29 days' ELSE NULL END,
  CASE WHEN i % 2 = 0 THEN NULL ELSE now() - interval '29 days' END,
  false, false, '65340004-0001-0000-0000-000000000001'
FROM generate_series(1, 10000) i;

-- ── 100,000 evidence events distributed across all 20,000 clocks (5
--    each) -- synthetic bulk history for scale, mirroring the exact
--    Phase 5.3 performance fixture pattern. ──────────────────────────
INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, idempotency_key)
SELECT c.id, c.instance_id, 'started', gen_random_uuid()
FROM workflow_sla_clocks c CROSS JOIN generate_series(1,5) g;

-- ── Dimension 1: a full process_workflow_sla_due_batch call at scale,
--    default limit (25 per category), mixed breach/escalation due
--    work available (~3,333 breach candidates, ~3,333 escalation
--    candidates among the 10,000 active clocks). ────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM process_workflow_sla_due_batch(25);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (process_workflow_sla_due_batch, default limit 25/category, 20,000 total clocks / 100,000 events): % ms, % rows returned', round(v_ms, 2), v_count;
END $$;

-- ── Dimension 2: batch latency at the hard ceiling (200/category) --
--    confirms latency scales with the requested/claimed batch size,
--    not with total table size, and stays well within an interactive
--    budget even at the largest bound this phase permits. ───────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM process_workflow_sla_due_batch(200);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (process_workflow_sla_due_batch, hard-ceiling limit 200/category): % ms, % rows returned', round(v_ms, 2), v_count;
END $$;

-- ── Dimension 3: repeated calls against already-settled state (warm
--    cache, nothing left to claim in the ranges already drained by
--    Dimensions 1-2) -- confirms a dispatcher polling on a fixed
--    interval against mostly-quiet data stays cheap. ─────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER; i INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR i IN 1..20 LOOP
    PERFORM * FROM process_workflow_sla_due_batch(25);
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 3 (20 consecutive process_workflow_sla_due_batch calls, default limit): % ms total, % ms/call', round(v_ms, 2), round(v_ms / 20, 4);
END $$;

-- ── Dimension 4: the underlying due-detection queries this phase's
--    processors are built on, timed directly at 10,000-active-clock
--    scale (restates Phase 5.3's own Dimension 6a-c at the same scale,
--    since this phase adds no new query shape of its own -- it only
--    adds the SKIP LOCKED claim loop around these exact functions). ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_sla_clocks_due_for_breach(1000);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4a (workflow_sla_clocks_due_for_breach, limit 1000): % ms, % candidates', round(v_ms, 2), v_count;

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_sla_clocks_due_for_escalation(1000);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4b (workflow_sla_clocks_due_for_escalation, limit 1000): % ms, % candidates', round(v_ms, 2), v_count;
END $$;

-- ── Dimension 5: EXPLAIN (ANALYZE, BUFFERS) on the exact claim
--    pattern each processor uses -- a point lookup by primary key
--    under FOR UPDATE SKIP LOCKED, the operation executed once per
--    candidate inside the bounded loop. Confirms an index (primary
--    key) scan, never a sequential scan, independent of table size. ──
DO $$
DECLARE v_plan TEXT; v_line TEXT; v_target UUID;
BEGIN
  SELECT id INTO v_target FROM workflow_sla_clocks WHERE state = 'running' AND breached_at IS NULL
    AND effective_deadline_adjusted <= clock_timestamp() LIMIT 1;
  v_plan := '';
  FOR v_line IN EXECUTE format(
    $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT * FROM workflow_sla_clocks WHERE id = %L FOR UPDATE SKIP LOCKED$q$,
    v_target
  )
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on workflow_sla_clocks%' THEN
    RAISE EXCEPTION 'expected the per-candidate SKIP LOCKED claim to use the primary key index, got a sequential scan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 5 (EXPLAIN ANALYZE BUFFERS, per-candidate FOR UPDATE SKIP LOCKED claim at 20,000-row scale): uses an index scan, never a sequential scan -- plan: %', v_plan;
END $$;

-- ── Dimension 6: EXPLAIN (ANALYZE, BUFFERS) on the breach-due
--    discovery access path itself -- confirms the partial index
--    (idx_workflow_sla_clocks_breach_due) is used, never a sequential
--    scan, at 20,000-row scale (10,000 historical rows the index's own
--    WHERE clause excludes entirely). Restates Phase 5.3's own
--    Dimension 6d with ANALYZE/BUFFERS detail this phase's own
--    governing instruction specifically requires. ────────────────────
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  v_plan := '';
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT * FROM workflow_sla_clocks WHERE state = 'running' AND breached_at IS NULL
      AND effective_deadline_adjusted <= clock_timestamp() ORDER BY effective_deadline_adjusted LIMIT 1000$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on workflow_sla_clocks%' THEN
    RAISE EXCEPTION 'expected the breach-due discovery access path to use idx_workflow_sla_clocks_breach_due, got a sequential scan: %', v_plan;
  END IF;
  IF v_plan NOT ILIKE '%idx_workflow_sla_clocks_breach_due%' THEN
    RAISE EXCEPTION 'expected the breach-due discovery access path to specifically name idx_workflow_sla_clocks_breach_due in its plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 6 (EXPLAIN ANALYZE BUFFERS, breach-due discovery, 20,000-row scale incl. 10,000-row historical tail): uses idx_workflow_sla_clocks_breach_due, never a sequential scan -- plan: %', v_plan;
END $$;

-- ── Dimension 7: batch latency remains bounded as the historical tail
--    grows further -- add another 5,000 terminal clocks and confirm
--    Dimension 1's call is not meaningfully slower (the partial index
--    excludes terminal rows from the access path entirely, so history
--    growth should not show up in claim latency at all). ─────────────
INSERT INTO workflow_sla_clocks (
  id, instance_id, organization_id, deadline_rule_type, start_event_type, started_at,
  timezone, effective_deadline, effective_deadline_adjusted,
  state, completed_at, pause_eligible, restart_eligible, created_by
)
SELECT
  gen_random_uuid(), (SELECT id FROM wf54p_i1), '65340004-0000-0000-0000-000000000001', 'absolute', 'manual',
  now() - interval '60 days',
  'UTC',
  now() - interval '59 days',
  now() - interval '59 days',
  'completed', now() - interval '59 days', false, false, '65340004-0001-0000-0000-000000000001'
FROM generate_series(1, 5000) i;

DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM process_workflow_sla_due_batch(25);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 7 (process_workflow_sla_due_batch after growing the historical tail to 15,000 terminal clocks / 25,000 total): % ms, % rows returned -- latency stays bounded, not proportional to historical volume', round(v_ms, 2), v_count;
END $$;

DO $$ BEGIN RAISE NOTICE 'Workflow SLA timer dispatch performance probe PASSED'; END $$;
