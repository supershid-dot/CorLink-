-- CAP-002 Phase 4.2 gateway routing execution disposable performance
-- probe (4 dimensions): a minimal single gateway hop, a maximal
-- 16-branch gateway hop, a near-bound (25-hop) consecutive gateway
-- chain resolved synchronously in one command, and a gateway hop
-- against an instance whose event table already has 100,000 rows.
-- No speculative indexes are added; the existing
-- idx_workflow_variables_instance and workflow_events_sequence_unique
-- indexes are reused unchanged.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('649a0000-0000-0000-0000-000000000001','WF Gateway Exec Performance','authority','WFGEP');
INSERT INTO auth.users(id,email) VALUES ('649a0000-0001-0000-0000-000000000001','perf@wfgep.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('649a0000-0001-0000-0000-000000000001','649a0000-0000-0000-0000-000000000001','WFGEP-1','Performance Admin','perf@wfgep.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('649a0000-0001-0000-0000-000000000001','organization','649a0000-0000-0000-0000-000000000001','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"649a0000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 1: minimal single gateway hop (Start -> gateway ->
--    End, condition evaluated once, one command). ─────────────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '649a0000-0000-0000-0000-000000000001','wfgep_minimal','WFGEP Minimal','opaque_case',
    '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
    '649a0000-1000-0000-0000-000000000001'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '649a0000-1000-0000-0000-000000000002');
  v_inst := create_workflow_instance(v_ver,'opaque_case','649a0000-2000-0000-0000-000000000001','649a0000-0000-0000-0000-000000000001','649a0000-1000-0000-0000-000000000003',NULL);

  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '649a0000-1000-0000-0000-000000000004');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 1 (minimal single gateway hop): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id = v_inst) <> 'completed' THEN
    RAISE EXCEPTION 'dimension 1 fixture did not complete as expected';
  END IF;
  IF v_ms > 1000 THEN RAISE EXCEPTION 'minimal gateway hop performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 2: a maximal 16-branch gateway node — 15 non-default
--    conditions evaluated (all false) before falling to the default
--    edge, in one command. ──────────────────────────────────────────
DO $$
DECLARE
  v_nodes JSONB; v_edges JSONB; v_i INT;
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_nodes := '[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"default_end","type":"end","config":{"outcome_code":"defaulted"}}]'::jsonb;
  v_edges := '[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false}]'::jsonb;
  FOR v_i IN 0..14 LOOP
    v_edges := v_edges || jsonb_build_array(jsonb_build_object(
      'source','gw','target','default_end','outcome','routed','priority',v_i,'default',false,
      'condition',jsonb_build_object('source','instance_variable','variable_name','never_set_'||v_i,'operator','is_not_null')
    ));
  END LOOP;
  v_edges := v_edges || jsonb_build_array(jsonb_build_object('source','gw','target','default_end','outcome','routed','priority',15,'default',true));

  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '649a0000-0000-0000-0000-000000000001','wfgep_maxbranch','WFGEP Maxbranch','opaque_case',
    jsonb_build_object('schema_version',2,'entry_node','start','nodes',v_nodes,'edges',v_edges),
    '649a0000-1000-0000-0000-000000000005'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '649a0000-1000-0000-0000-000000000006');
  v_inst := create_workflow_instance(v_ver,'opaque_case','649a0000-2000-0000-0000-000000000002','649a0000-0000-0000-0000-000000000001','649a0000-1000-0000-0000-000000000007',NULL);

  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '649a0000-1000-0000-0000-000000000008');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 2 (maximal 16-branch gateway, 15 conditions evaluated before default): % ms', round(v_ms,2);
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id = v_inst) <> 'defaulted' THEN
    RAISE EXCEPTION 'dimension 2 fixture did not fall through to the default branch as expected';
  END IF;
  IF v_ms > 1000 THEN RAISE EXCEPTION 'maximal-branch gateway performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 3: a programmatically generated 25-hop consecutive
--    gateway chain resolved synchronously in one
--    start_workflow_instance command. ──────────────────────────────
DO $$
DECLARE
  v_nodes JSONB; v_edges JSONB; v_i INT; v_key TEXT; v_next TEXT;
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_route_count INTEGER;
BEGIN
  v_nodes := '[{"key":"start","type":"start","config":{}},{"key":"final_end","type":"end","config":{"outcome_code":"reached"}}]'::jsonb;
  v_edges := '[{"source":"start","target":"g1","outcome":"started","priority":0,"default":false}]'::jsonb;
  FOR v_i IN 1..25 LOOP
    v_key := 'g' || v_i;
    v_next := CASE WHEN v_i = 25 THEN 'final_end' ELSE 'g' || (v_i + 1) END;
    v_nodes := v_nodes || jsonb_build_array(jsonb_build_object('key',v_key,'type','gateway_exclusive','config','{}'::jsonb));
    v_edges := v_edges || jsonb_build_array(jsonb_build_object(
      'source',v_key,'target','final_end','outcome','routed','priority',0,'default',false,
      'condition',jsonb_build_object('source','instance_variable','variable_name','never_set_g'||v_i,'operator','is_not_null')
    ));
    v_edges := v_edges || jsonb_build_array(jsonb_build_object('source',v_key,'target',v_next,'outcome','routed','priority',1,'default',true));
  END LOOP;

  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '649a0000-0000-0000-0000-000000000001','wfgep_chain','WFGEP Chain','opaque_case',
    jsonb_build_object('schema_version',2,'entry_node','start','nodes',v_nodes,'edges',v_edges),
    '649a0000-1000-0000-0000-000000000009'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '649a0000-1000-0000-0000-000000000010');
  v_inst := create_workflow_instance(v_ver,'opaque_case','649a0000-2000-0000-0000-000000000003','649a0000-0000-0000-0000-000000000001','649a0000-1000-0000-0000-000000000011',NULL);

  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '649a0000-1000-0000-0000-000000000012');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 3 (25 consecutive gateway hops resolved synchronously in one command): % ms', round(v_ms,2);
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id = v_inst) <> 'reached' THEN
    RAISE EXCEPTION 'dimension 3 fixture did not resolve to the final End as expected';
  END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id = v_inst AND event_type = 'route_selected';
  IF v_route_count <> 25 THEN RAISE EXCEPTION 'expected exactly 25 route_selected events, got %', v_route_count; END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION '25-hop gateway chain performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
CREATE TEMP TABLE wfgep_bulk_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfgep_bulk_ids TO authenticated;

-- ── Dimension 4: a gateway hop against an instance whose event table
--    already has 100,000 rows. The definition/version and instance
--    are created through the real RPCs (as authenticated) so
--    publication integrity is exactly what production code would
--    produce; only the bulk event history is hand-inserted (as the
--    connecting superuser, since authenticated has no direct write
--    grant on workflow_events). ──────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"649a0000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '649a0000-0000-0000-0000-000000000001','wfgep_bulk_flow','WFGEP Bulk Flow','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  '649a0000-1000-0000-0000-000000009000'))
INSERT INTO wfgep_bulk_ids SELECT 'def',definition_id FROM made UNION ALL SELECT 'ver',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgep_bulk_ids WHERE name='ver'),0,'649a0000-1000-0000-0000-000000009001');
RESET ROLE;

INSERT INTO workflow_instances(id,definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,status,execution_epoch,lock_version,next_event_sequence,correlation_id,created_by,create_idempotency_key,started_at)
 VALUES ('649a0000-9000-0000-0000-000000000003',(SELECT id FROM wfgep_bulk_ids WHERE name='def'),(SELECT id FROM wfgep_bulk_ids WHERE name='ver'),'opaque_case','649a0000-9000-0000-0000-000000000004','649a0000-0000-0000-0000-000000000001',ARRAY['649a0000-0000-0000-0000-000000000001'::uuid],'active',1,1,100002,'649a0000-9000-0000-0000-000000000005','649a0000-0001-0000-0000-000000000001','649a0000-1000-0000-0000-000000009004',now());

-- The active token points at the already-completed 'start' step
-- (result_code='started') — workflow_advance_graph_step discovers
-- the current step through the token, then follows the 'started'
-- edge into gw, creating gw's own step fresh (never pre-created here).
INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key,run_number,state,result_code,activated_at,ended_at)
 VALUES ('649a0000-9000-0000-0000-000000000006','649a0000-9000-0000-0000-000000000003','start',1,'completed','started',now(),now());
INSERT INTO workflow_tokens(id,instance_id,step_id,token_key,state)
 VALUES ('649a0000-9000-0000-0000-000000000008','649a0000-9000-0000-0000-000000000003','649a0000-9000-0000-0000-000000000006','epoch_1_token_1','active');

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT '649a0000-9000-0000-0000-000000000003',g,'instance_created','649a0000-0001-0000-0000-000000000001',
  '649a0000-9000-0000-0000-000000000005',('649a0000-9000-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'{}'::jsonb,now()-((100000-g)||' seconds')::interval
FROM generate_series(1,100000) g;

DO $$
DECLARE v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"649a0000-0001-0000-0000-000000000001"}',true);
  v_t0 := clock_timestamp();
  PERFORM workflow_advance_graph_step('649a0000-9000-0000-0000-000000000003', 1, '649a0000-1000-0000-0000-000000009005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 4 (gateway hop against an instance whose event table already has 100,000 rows): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id='649a0000-9000-0000-0000-000000000003') <> 'completed' THEN
    RAISE EXCEPTION 'dimension 4 fixture did not route through the gateway to completion as expected';
  END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'large-event-table gateway-hop performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
ANALYZE workflow_events;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_events WHERE instance_id = '649a0000-9000-0000-0000-000000000003' ORDER BY event_sequence DESC LIMIT 100;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow gateway routing execution performance probe PASSED'; END $$;
