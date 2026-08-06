-- CAP-002 Phase 3.2 approval round lifecycle disposable performance probe
-- Disposable local PostgreSQL only. Measures the new bounded
-- synchronous skip loop inside workflow_enter_downstream_node across
-- three dimensions: a minimal single skip hop, a near-bound (25-hop)
-- consecutive skip chain in one command, and a skip hop against an
-- instance whose event table already has 100,000 rows.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('67830000-0000-0000-0000-000000000001','WF Round Lifecycle Performance','authority','WFRLP');
INSERT INTO auth.users(id,email) VALUES ('67830000-0001-0000-0000-000000000001','perf@wfrlp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('67830000-0001-0000-0000-000000000001','67830000-0000-0000-0000-000000000001','WFRLP-1','Performance Admin','perf@wfrlp.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67830000-0001-0000-0000-000000000001','organization','67830000-0000-0000-0000-000000000001','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67830000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 1: minimal single skip hop (Start -> zero-candidate
--    optional -> End, one command). ────────────────────────────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '67830000-0000-0000-0000-000000000001','wfrlp_minimal','WFRLP Minimal','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"r1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"none1","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"x_dead_end","type":"end","config":{"outcome_code":"x"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"r1","outcome":"started","priority":0,"default":false},{"source":"r1","target":"x_dead_end","outcome":"approved","priority":0,"default":false},{"source":"r1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"r1","target":"s_end","outcome":"skipped","priority":0,"default":false}]}'::jsonb,
    '67830000-1000-0000-0000-000000000001'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '67830000-1000-0000-0000-000000000002');
  v_t0 := clock_timestamp();
  v_inst := create_workflow_instance(v_ver,'opaque_case','67830000-2000-0000-0000-000000000001','67830000-0000-0000-0000-000000000001','67830000-1000-0000-0000-000000000003',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '67830000-1000-0000-0000-000000000004');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 1 (minimal single skip hop, Start->skip->End): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id=v_inst) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_inst) <> 's' THEN
    RAISE EXCEPTION 'dimension 1 fixture did not skip through to s_end as expected';
  END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'minimal skip-hop performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 2: a near-bound (25 consecutive) zero-candidate
--    optional skip chain resolved synchronously in one command. ────
DO $$
DECLARE
  v_nodes JSONB := '[{"key":"start","type":"start","config":{}}]'::jsonb;
  v_edges JSONB := '[]'::jsonb;
  v_hops INTEGER := 25;
  i INTEGER;
  v_node_key TEXT;
  v_prev_key TEXT := 'start';
  v_payload JSONB;
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  FOR i IN 1..v_hops LOOP
    v_node_key := 'r' || i;
    v_nodes := v_nodes || jsonb_build_array(jsonb_build_object(
      'key', v_node_key, 'type', 'approval', 'config', jsonb_build_object(
        'delivery_mode','parallel','decision_rule','majority','minimum_approvals',NULL,
        'requirement','optional','optional_policy','skip_if_no_candidates','allow_abstain',true,
        'reject_behavior','when_approval_impossible','allow_self_approval',false,'allow_multi_capacity',false,
        'minimum_candidates',1,
        'candidate_selectors', jsonb_build_array(jsonb_build_object('key','none'||i,'order',1,'type','organization_role','organization','home','role','assigned_receiver')),
        'comment_policy', jsonb_build_object('approve','optional','reject','required','abstain','optional')
      )
    ));
    v_edges := v_edges || jsonb_build_array(jsonb_build_object(
      'source', v_prev_key, 'target', v_node_key,
      'outcome', CASE WHEN v_prev_key='start' THEN 'started' ELSE 'skipped' END,
      'priority', 0, 'default', false
    ));
    v_edges := v_edges || jsonb_build_array(
      jsonb_build_object('source', v_node_key, 'target', 'x_dead_end', 'outcome', 'approved', 'priority', 0, 'default', false),
      jsonb_build_object('source', v_node_key, 'target', 'r_end', 'outcome', 'rejected', 'priority', 0, 'default', false)
    );
    v_prev_key := v_node_key;
  END LOOP;
  v_edges := v_edges || jsonb_build_array(jsonb_build_object(
    'source', v_prev_key, 'target', 's_end', 'outcome', 'skipped', 'priority', 0, 'default', false
  ));
  v_nodes := v_nodes || jsonb_build_array(
    jsonb_build_object('key','x_dead_end','type','end','config',jsonb_build_object('outcome_code','x')),
    jsonb_build_object('key','r_end','type','end','config',jsonb_build_object('outcome_code','r')),
    jsonb_build_object('key','s_end','type','end','config',jsonb_build_object('outcome_code','s'))
  );
  v_payload := jsonb_build_object('schema_version',1,'entry_node','start','nodes',v_nodes,'edges',v_edges);

  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '67830000-0000-0000-0000-000000000001','wfrlp_chain','WFRLP Chain','opaque_case', v_payload,
    '67830000-1000-0000-0000-000000000005'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '67830000-1000-0000-0000-000000000006');
  v_t0 := clock_timestamp();
  v_inst := create_workflow_instance(v_ver,'opaque_case','67830000-2000-0000-0000-000000000002','67830000-0000-0000-0000-000000000001','67830000-1000-0000-0000-000000000007',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '67830000-1000-0000-0000-000000000008');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 2 (% consecutive zero-candidate skips resolved synchronously in one command): % ms', v_hops, round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id=v_inst) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_inst) <> 's' THEN
    RAISE EXCEPTION 'dimension 2 fixture did not chain through all % skips to s_end as expected', v_hops;
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_inst AND outcome_code='skipped') <> v_hops THEN
    RAISE EXCEPTION 'expected % skipped rounds, got %', v_hops,
      (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_inst AND outcome_code='skipped');
  END IF;
  IF v_ms > 3000 THEN RAISE EXCEPTION '25-hop skip-chain performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
CREATE TEMP TABLE wfrlp_bulk_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrlp_bulk_ids TO authenticated;

-- ── Dimension 3: a single skip hop against an instance whose event
--    table already has 100,000 rows. The definition/version and
--    instance are created through the real RPCs (as authenticated)
--    so publication integrity is exactly what production code would
--    produce; only the bulk event history is hand-inserted. ───────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67830000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '67830000-0000-0000-0000-000000000001','wfrlp_bulk_flow','WFRLP Bulk Flow','opaque_case',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"r1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"none1","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"x_dead_end","type":"end","config":{"outcome_code":"x"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"r1","outcome":"started","priority":0,"default":false},{"source":"r1","target":"x_dead_end","outcome":"approved","priority":0,"default":false},{"source":"r1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"r1","target":"s_end","outcome":"skipped","priority":0,"default":false}]}'::jsonb,
  '67830000-1000-0000-0000-000000009000'))
INSERT INTO wfrlp_bulk_ids SELECT 'def',definition_id FROM made UNION ALL SELECT 'ver',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlp_bulk_ids WHERE name='ver'),0,'67830000-1000-0000-0000-000000009001');
RESET ROLE;

INSERT INTO workflow_instances(id,definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,status,execution_epoch,lock_version,next_event_sequence,correlation_id,created_by,create_idempotency_key,started_at)
 VALUES ('67830000-9000-0000-0000-000000000003',(SELECT id FROM wfrlp_bulk_ids WHERE name='def'),(SELECT id FROM wfrlp_bulk_ids WHERE name='ver'),'opaque_case','67830000-9000-0000-0000-000000000004','67830000-0000-0000-0000-000000000001',ARRAY['67830000-0000-0000-0000-000000000001'::uuid],'active',1,1,100002,'67830000-9000-0000-0000-000000000005','67830000-0001-0000-0000-000000000001','67830000-1000-0000-0000-000000009004',now());

-- The active token points at the already-completed 'start' step
-- (result_code='started') — workflow_advance_graph_step discovers
-- the current step through the token, then follows the 'started'
-- edge into r1, creating r1's own step fresh (never pre-created here).
INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key,run_number,state,result_code,activated_at,ended_at)
 VALUES ('67830000-9000-0000-0000-000000000006','67830000-9000-0000-0000-000000000003','start',1,'completed','started',now(),now());
INSERT INTO workflow_tokens(id,instance_id,step_id,token_key,state)
 VALUES ('67830000-9000-0000-0000-000000000008','67830000-9000-0000-0000-000000000003','67830000-9000-0000-0000-000000000006','epoch_1_token_1','active');

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT '67830000-9000-0000-0000-000000000003',g,'instance_created','67830000-0001-0000-0000-000000000001',
  '67830000-9000-0000-0000-000000000005',('67830000-9000-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'{}'::jsonb,now()-((100000-g)||' seconds')::interval
FROM generate_series(1,100000) g;

DO $$
DECLARE v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"67830000-0001-0000-0000-000000000001"}',true);
  v_t0 := clock_timestamp();
  PERFORM workflow_advance_graph_step('67830000-9000-0000-0000-000000000003', 1, '67830000-1000-0000-0000-000000009005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 3 (skip hop against an instance whose event table already has 100,000 rows): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id='67830000-9000-0000-0000-000000000003') <> 'completed' THEN
    RAISE EXCEPTION 'dimension 3 fixture did not skip through to completion as expected';
  END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'large-event-table skip-hop performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
ANALYZE workflow_events;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_events WHERE instance_id = '67830000-9000-0000-0000-000000000003' ORDER BY event_sequence DESC LIMIT 100;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow approval round lifecycle performance probe PASSED'; END $$;
