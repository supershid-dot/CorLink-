-- CAP-002 Phase 2C.1 disposable performance probe
-- Disposable local PostgreSQL only. Measures workflow_advance_graph_step
-- across the dimensions new to this milestone: a minimal single-hop
-- advancement, a maximal 100-candidate second-hop candidate snapshot,
-- and advancement against an instance whose event table already has
-- 100,000 rows (current-step discovery via the sole active token,
-- plus the same publication re-verification 2B.2 already proved
-- scalable, now exercised from a non-Start source step).
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('66800000-0000-0000-0000-000000000001','WF Graph Advancement Performance','authority','WFGAP');
INSERT INTO auth.users(id,email) VALUES
 ('66800000-0001-0000-0000-000000000001','perf@wfgap.local'),
 ('66800000-0001-0000-0000-000000000002','perf-sup@wfgap.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('66800000-0001-0000-0000-000000000001','66800000-0000-0000-0000-000000000001','WFGAP-1','Performance Admin','perf@wfgap.local',true,true);
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('66800000-0001-0000-0000-000000000002','66800000-0000-0000-0000-000000000001','WFGAP-2','Performance Supervisor','perf-sup@wfgap.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('66800000-0001-0000-0000-000000000001','organization','66800000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66800000-0001-0000-0000-000000000002','organization','66800000-0000-0000-0000-000000000001','supervisor',true,true);

-- Test-only SECURITY DEFINER helper simulating "a decision has
-- already been recorded" — this milestone implements only the
-- mechanical outcome-to-edge routine, never the decision itself
-- (Phase 3's job), so the probe must manufacture the precondition
-- directly, exactly like the behavioral suite's own wfga_simulate_decision.
CREATE OR REPLACE FUNCTION wfgap_simulate_decision(p_instance_id UUID, p_node_key TEXT, p_result_code TEXT) RETURNS VOID AS $$
BEGIN
  UPDATE workflow_instance_steps SET state = 'completed', result_code = p_result_code, ended_at = now()
  WHERE instance_id = p_instance_id AND definition_node_key = p_node_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfgap_simulate_decision(UUID,TEXT,TEXT) TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66800000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 1: minimal single-hop advancement
--    (Approval[1 candidate] -> End) ────────────────────────────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '66800000-0000-0000-0000-000000000001','wfgap_minimal','WFGAP Minimal','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
    '66800000-1000-0000-0000-000000000001'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '66800000-1000-0000-0000-000000000002');
  v_inst := create_workflow_instance(v_ver,'opaque_case','66800000-2000-0000-0000-000000000001','66800000-0000-0000-0000-000000000001','66800000-1000-0000-0000-000000000003',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '66800000-1000-0000-0000-000000000004');
  PERFORM wfgap_simulate_decision(v_inst, 'review1', 'approved');
  v_t0 := clock_timestamp();
  PERFORM workflow_advance_graph_step(v_inst, 1, '66800000-1000-0000-0000-000000000005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 1 (minimal single-hop advancement, Approval->End): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'minimal-advancement performance regression: % ms', v_ms; END IF;
END $$;

-- 100 candidate users (a role held by no other fixture user) for the
-- maximal second-hop electorate scenario, seeded now (not earlier)
-- so Dimension 1's own minimal electorate is unaffected.
RESET ROLE;
INSERT INTO auth.users(id,email)
SELECT ('66800000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'perf-cand-'||g||'@wfgap.local' FROM generate_series(1,100) g;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('66800000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'66800000-0000-0000-0000-000000000001',
 'WFGAP-C-'||g,'Perf Candidate '||g,'perf-cand-'||g||'@wfgap.local',true FROM generate_series(1,100) g;
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active)
SELECT ('66800000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'organization','66800000-0000-0000-0000-000000000001','assigned_receiver',false,true
FROM generate_series(1,100) g;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66800000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 2: maximal 100-candidate second-hop snapshot ─────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '66800000-0000-0000-0000-000000000001','wfgap_max_electorate','WFGAP Max Electorate','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
    '66800000-1000-0000-0000-000000000006'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '66800000-1000-0000-0000-000000000007');
  v_inst := create_workflow_instance(v_ver,'opaque_case','66800000-2000-0000-0000-000000000002','66800000-0000-0000-0000-000000000001','66800000-1000-0000-0000-000000000008',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '66800000-1000-0000-0000-000000000009');
  PERFORM wfgap_simulate_decision(v_inst, 'review1', 'approved');
  v_t0 := clock_timestamp();
  PERFORM workflow_advance_graph_step(v_inst, 1, '66800000-1000-0000-0000-000000000010');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  SELECT count(*) INTO v_count FROM workflow_approval_positions WHERE instance_id = v_inst AND round_id IN (
    SELECT id FROM workflow_approval_rounds WHERE instance_id = v_inst AND step_id IN (
      SELECT id FROM workflow_instance_steps WHERE instance_id = v_inst AND definition_node_key='review2'));
  RAISE NOTICE 'Dimension 2 (maximum 100-position second-hop candidate snapshot, % positions): % ms', v_count, round(v_ms,2);
  IF v_count <> 100 THEN RAISE EXCEPTION 'expected exactly 100 resolved positions on the second hop, got %', v_count; END IF;
  IF v_ms > 3000 THEN RAISE EXCEPTION 'maximal-electorate advancement performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
CREATE TEMP TABLE wfgap_bulk_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfgap_bulk_ids TO authenticated;

-- ── Dimension 3: advancement against an instance whose event table
--    already has 100,000 rows ────────────────────────────────────
-- The definition/version is created through the real RPC (as
-- authenticated) so its canonical payload and content_hash are
-- exactly what canonicalize_workflow_definition_payload() itself
-- would produce — hand-crafting this JSON risks a byte mismatch
-- against the re-verification check, which is real production logic,
-- not a probe-only convenience to bypass.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66800000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66800000-0000-0000-0000-000000000001','wfgap_bulk_flow','WFGAP Bulk Flow','opaque_case',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '66800000-1000-0000-0000-000000009000'))
INSERT INTO wfgap_bulk_ids SELECT 'def',definition_id FROM made UNION ALL SELECT 'ver',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgap_bulk_ids WHERE name='ver'),0,'66800000-1000-0000-0000-000000009001');
RESET ROLE;

INSERT INTO workflow_instances(id,definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,status,execution_epoch,lock_version,next_event_sequence,correlation_id,created_by,create_idempotency_key,started_at)
 VALUES ('66800000-9000-0000-0000-000000000003',(SELECT id FROM wfgap_bulk_ids WHERE name='def'),(SELECT id FROM wfgap_bulk_ids WHERE name='ver'),'opaque_case','66800000-9000-0000-0000-000000000004','66800000-0000-0000-0000-000000000001',ARRAY['66800000-0000-0000-0000-000000000001'::uuid],'active',1,1,100002,'66800000-9000-0000-0000-000000000005','66800000-0001-0000-0000-000000000001','66800000-1000-0000-0000-000000009004',now());

INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key,run_number,state,result_code,activated_at,ended_at)
 VALUES ('66800000-9000-0000-0000-000000000006','66800000-9000-0000-0000-000000000003','start',1,'completed','started',now(),now());
INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key,run_number,state,result_code,activated_at,ended_at)
 VALUES ('66800000-9000-0000-0000-000000000007','66800000-9000-0000-0000-000000000003','review1',1,'completed','approved',now(),now());
INSERT INTO workflow_tokens(id,instance_id,step_id,token_key,state)
 VALUES ('66800000-9000-0000-0000-000000000008','66800000-9000-0000-0000-000000000003','66800000-9000-0000-0000-000000000007','epoch_1_token_1','active');

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT '66800000-9000-0000-0000-000000000003',g,'instance_created','66800000-0001-0000-0000-000000000001',
  '66800000-9000-0000-0000-000000000005',('66800000-9000-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'{}'::jsonb,now()-((100000-g)||' seconds')::interval
FROM generate_series(1,100000) g;

DO $$
DECLARE v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"66800000-0001-0000-0000-000000000001"}',true);
  v_t0 := clock_timestamp();
  PERFORM workflow_advance_graph_step('66800000-9000-0000-0000-000000000003', 1, '66800000-1000-0000-0000-000000009005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 3 (advancement against an instance whose event table already has 100,000 rows): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'large-event-table advancement performance regression: % ms', v_ms; END IF;
END $$;

-- Statistics on the just-bulk-inserted rows are stale within this
-- single transaction (autovacuum has not run); ANALYZE so the
-- diagnostic EXPLAIN below reflects steady-state planning, not a
-- transient cold-statistics artifact.
RESET ROLE;
ANALYZE workflow_events;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_events WHERE instance_id = '66800000-9000-0000-0000-000000000003' ORDER BY event_sequence DESC LIMIT 100;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow graph advancement foundation performance probe PASSED'; END $$;
