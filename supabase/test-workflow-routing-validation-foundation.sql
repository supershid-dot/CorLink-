-- CAP-002 Phase 4.1 routing validation and variable foundation —
-- behavioral suite. Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

CREATE TEMP TABLE wfrv_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrv_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrv_results, wfrv_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64900000-0000-0000-0000-000000000001','WF Routing Validation A','authority','WFRV-A'),
 ('64900000-0000-0000-0000-000000000002','WF Routing Validation B','authority','WFRV-B');
INSERT INTO auth.users(id,email) VALUES
 ('64900000-0001-0000-0000-000000000001','admin@wfrv.local'),
 ('64900000-0001-0000-0000-000000000002','outsider@wfrv.local'),
 ('64900000-0001-0000-0000-000000000003','otherorg@wfrv.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('64900000-0001-0000-0000-000000000001','64900000-0000-0000-0000-000000000001','WFRV-1','Admin','admin@wfrv.local',true),
 ('64900000-0001-0000-0000-000000000002','64900000-0000-0000-0000-000000000001','WFRV-2','Outsider','outsider@wfrv.local',true),
 ('64900000-0001-0000-0000-000000000003','64900000-0000-0000-0000-000000000002','WFRV-3','OtherOrg','otherorg@wfrv.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64900000-0001-0000-0000-000000000001','organization','64900000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64900000-0001-0000-0000-000000000002','organization','64900000-0000-0000-0000-000000000001','staff',true,true),
 ('64900000-0001-0000-0000-000000000003','organization','64900000-0000-0000-0000-000000000002','authority_admin',true,true);

\set VALID_GATEWAY_PAYLOAD '\'{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"priority_band","operator":"equals","value_type":"string","value":"urgent"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}\''

-- Helper: assert that creating a definition with a given broken
-- payload is rejected, and that SQLERRM contains the expected rule
-- code (mirrors test-workflow-executable-definition-validation.sql's
-- own wfv_assert_create_rejected, redefined locally to keep this
-- suite independently runnable).
CREATE OR REPLACE FUNCTION wfrv_assert_create_rejected(p_key TEXT, p_payload JSONB, p_idem UUID, p_rule TEXT) RETURNS VOID AS $$
DECLARE v_msg TEXT;
BEGIN
  BEGIN
    PERFORM create_workflow_definition(
      '64900000-0000-0000-0000-000000000001', p_key, 'x', 'opaque_case', p_payload, p_idem
    );
    RAISE EXCEPTION 'wfrv_test_failure: expected rejection for rule % but creation succeeded', p_rule;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'wfrv_test_failure%' THEN RAISE; END IF;
    IF v_msg NOT LIKE ('%rule=' || p_rule || '%') THEN
      RAISE EXCEPTION 'wfrv_test_failure: expected rule=% but got: %', p_rule, v_msg;
    END IF;
  END;
END;
$$ LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION wfrv_assert_create_rejected(TEXT, JSONB, UUID, TEXT) TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64900000-0001-0000-0000-000000000001"}',false);

-- ── 1: a fully valid schema_version=2 gateway_exclusive definition
--    creates and canonicalizes, storing capability_version=2. ─────
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '64900000-0000-0000-0000-000000000001','wfrv_gw1','WFRV GW1','opaque_case',
  :VALID_GATEWAY_PAYLOAD::jsonb, '64900000-1000-0000-0000-000000000001'))
INSERT INTO wfrv_ids SELECT 'gw1_def', definition_id FROM made UNION ALL SELECT 'gw1_v', version_id FROM made;
DO $$
BEGIN
  IF (SELECT capability_version FROM workflow_definition_versions WHERE id = (SELECT id FROM wfrv_ids WHERE name='gw1_v')) <> 2
     OR (SELECT definition_payload ->> 'schema_version' FROM workflow_definition_versions WHERE id = (SELECT id FROM wfrv_ids WHERE name='gw1_v')) <> '2'
  THEN RAISE EXCEPTION 'expected capability_version=2 and payload schema_version=2'; END IF;
END $$;
INSERT INTO wfrv_results VALUES (1,'a valid schema_version=2 gateway_exclusive definition creates and stores capability_version=2');

-- ── 2: it publishes successfully. ─────────────────────────────────
SELECT publish_workflow_definition_version((SELECT id FROM wfrv_ids WHERE name='gw1_v'),0,'64900000-1000-0000-0000-000000000002');
DO $$ BEGIN IF (SELECT status FROM workflow_definition_versions WHERE id=(SELECT id FROM wfrv_ids WHERE name='gw1_v')) <> 'published'
  THEN RAISE EXCEPTION 'expected published status'; END IF; END $$;
INSERT INTO wfrv_results VALUES (2,'a valid schema_version=2 gateway_exclusive definition publishes successfully');

-- ── 3: gateway_exclusive is rejected under schema_version=1
--    (Version 1''s node-type allowlist is unchanged). ──────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_v1gw',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":true}]}'::jsonb,
  gen_random_uuid(),'invalid_node_type');
INSERT INTO wfrv_results VALUES (3,'gateway_exclusive is rejected under schema_version=1');

-- ── 4: a gateway_exclusive node with non-empty config is rejected. ─
SELECT wfrv_assert_create_rejected('wfrv_bad_cfg',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{"x":1}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_config_not_empty');
INSERT INTO wfrv_results VALUES (4,'a gateway_exclusive node with non-empty config is rejected');

-- ── 5: a gateway with fewer than 2 outbound edges is rejected. ────
SELECT wfrv_assert_create_rejected('wfrv_bad_few',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_outbound_edges_count_invalid');
INSERT INTO wfrv_results VALUES (5,'a gateway with fewer than 2 outbound edges is rejected');

-- ── 6: a gateway with more than 16 outbound edges is rejected
--    (programmatically generate 17 branches). ─────────────────────
DO $$
DECLARE v_nodes JSONB; v_edges JSONB; v_i INT;
BEGIN
  v_nodes := '[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}}]'::jsonb;
  v_edges := '[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false}]'::jsonb;
  FOR v_i IN 0..16 LOOP
    v_nodes := v_nodes || jsonb_build_array(jsonb_build_object('key','e'||v_i,'type','end','config',jsonb_build_object('outcome_code','o'||v_i)));
    v_edges := v_edges || jsonb_build_array(
      CASE WHEN v_i = 16
        THEN jsonb_build_object('source','gw','target','e'||v_i,'outcome','routed','priority',v_i,'default',true)
        ELSE jsonb_build_object('source','gw','target','e'||v_i,'outcome','routed','priority',v_i,'default',false,
               'condition',jsonb_build_object('source','instance_variable','variable_name','v'||v_i,'operator','is_null'))
      END);
  END LOOP;
  PERFORM wfrv_assert_create_rejected('wfrv_bad_many',
    jsonb_build_object('schema_version',2,'entry_node','start','nodes',v_nodes,'edges',v_edges),
    gen_random_uuid(),'gateway_outbound_edges_count_invalid');
END $$;
INSERT INTO wfrv_results VALUES (6,'a gateway with more than 16 outbound edges is rejected');

-- ── 7: a gateway with zero default edges is rejected. ─────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_nodefault',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":false,"condition":{"source":"instance_variable","variable_name":"y","operator":"is_not_null"}}]}'::jsonb,
  gen_random_uuid(),'gateway_default_edge_invalid');
INSERT INTO wfrv_results VALUES (7,'a gateway with zero default edges is rejected');

-- ── 8: a gateway with two default edges is rejected. ──────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_twodefault',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":true},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_default_edge_invalid');
INSERT INTO wfrv_results VALUES (8,'a gateway with two default edges is rejected');

-- ── 9: a gateway with a duplicate priority is rejected. ───────────
SELECT wfrv_assert_create_rejected('wfrv_bad_dup_prio',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":0,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_duplicate_priority');
INSERT INTO wfrv_results VALUES (9,'a gateway with a duplicate priority among its outbound edges is rejected');

-- ── 10: a gateway edge whose outcome is not exactly ''routed''
--    is rejected. ──────────────────────────────────────────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_outcome',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"approved","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_edge_outcome_invalid');
INSERT INTO wfrv_results VALUES (10,'a gateway edge whose outcome is not exactly ''routed'' is rejected');

-- ── 11: a default edge carrying a condition is rejected. ──────────
SELECT wfrv_assert_create_rejected('wfrv_bad_default_cond',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true,"condition":{"source":"instance_variable","variable_name":"y","operator":"is_null"}}]}'::jsonb,
  gen_random_uuid(),'gateway_default_edge_has_condition');
INSERT INTO wfrv_results VALUES (11,'a default edge carrying a condition is rejected');

-- ── 12: a non-default gateway edge missing a condition is rejected. ─
SELECT wfrv_assert_create_rejected('wfrv_bad_missing_cond',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_missing');
INSERT INTO wfrv_results VALUES (12,'a non-default gateway edge with no condition object is rejected');

-- ── 13: an unsupported condition operator is rejected. ────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_operator',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"matches_regex","value_type":"string","value":"x"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_operator_unsupported');
INSERT INTO wfrv_results VALUES (13,'an unsupported condition operator is rejected');

-- ── 14: an operator/type mismatch (''in'' against ''boolean'') is
--    rejected. ──────────────────────────────────────────────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_op_type',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"in","value_type":"boolean","value":[true]}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_operator_type_mismatch');
INSERT INTO wfrv_results VALUES (14,'an operator/type mismatch (''in'' against ''boolean'') is rejected');

-- ── 15: an unsupported condition source (module_variable) is
--    rejected — module adapters are explicitly out of scope. ─────
SELECT wfrv_assert_create_rejected('wfrv_bad_source',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"module_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_source_unsupported');
INSERT INTO wfrv_results VALUES (15,'an unsupported condition source (module_variable) is rejected');

-- ── 16: an invalid variable_name format is rejected. ──────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_varname',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"Bad-Name","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_variable_name_invalid');
INSERT INTO wfrv_results VALUES (16,'an invalid condition variable_name format is rejected');

-- ── 17: a condition literal value that does not match its declared
--    value_type is rejected. ──────────────────────────────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_literal',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"equals","value_type":"uuid","value":"not-a-uuid"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_condition_value_invalid');
INSERT INTO wfrv_results VALUES (17,'a condition literal that does not match its declared value_type is rejected');

-- ── 18: a gateway node reachable from two distinct gateway sources
--    (gw1 and gw2, both routing into gw3) is ACCEPTED and publishes
--    successfully — ordinary reconvergence under the single-token
--    model (docs/69 "Merge behavior"; corrected by Phase 4.1A after
--    Phase 4.1 incorrectly rejected this). Publication's pipeline
--    re-verifies reachability and acyclicity as part of the same
--    validation pass that accepts this payload, so a successful
--    publish here is itself the proof the graph remains acyclic and
--    fully reachable (points 1 and 2 of the Phase 4.1A test
--    correction). Version 1 behavior is unaffected — see scenario 3,
--    unchanged, which still rejects gateway_exclusive under
--    schema_version=1 (point 4). This scenario creates a definition
--    only; no instance, token, or runtime execution is created or
--    touched, so no parallel-token or merge runtime behavior is
--    exercised or introduced here (point 5) — the structural
--    validator separately confirms workflow_enter_downstream_node
--    carries no gateway-execution logic at all. ───────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '64900000-0000-0000-0000-000000000001','wfrv_inbound_ok','WFRV Inbound OK','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw1","type":"gateway_exclusive","config":{}},{"key":"gw2","type":"gateway_exclusive","config":{}},{"key":"gw3","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}},{"key":"dead_end","type":"end","config":{"outcome_code":"d"}}],"edges":[{"source":"start","target":"gw1","outcome":"started","priority":0,"default":false},{"source":"gw1","target":"gw3","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw1","target":"gw2","outcome":"routed","priority":1,"default":true},{"source":"gw2","target":"gw3","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"z","operator":"is_null"}},{"source":"gw2","target":"dead_end","outcome":"routed","priority":1,"default":true},{"source":"gw3","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"y","operator":"is_null"}},{"source":"gw3","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  '64900000-1000-0000-0000-000000000020'))
INSERT INTO wfrv_ids SELECT 'inbound_ok_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrv_ids WHERE name='inbound_ok_v'),0,'64900000-1000-0000-0000-000000000021');
DO $$ BEGIN IF (SELECT status FROM workflow_definition_versions WHERE id=(SELECT id FROM wfrv_ids WHERE name='inbound_ok_v')) <> 'published'
  THEN RAISE EXCEPTION 'expected a gateway node with two distinct gateway-source inbound edges to publish successfully'; END IF; END $$;
INSERT INTO wfrv_results VALUES (18,'a gateway node reachable from two distinct gateway sources (two inbound edges) is accepted and publishes successfully — ordinary single-token reconvergence, not rejected');

-- ── 19: a gateway node with ZERO inbound edges is still rejected
--    (the one case the corrected rule does reject). ───────────────
SELECT wfrv_assert_create_rejected('wfrv_bad_zero_inbound',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"real_end","type":"end","config":{"outcome_code":"r"}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"real_end","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid(),'gateway_inbound_edges_invalid');
INSERT INTO wfrv_results VALUES (19,'a gateway_exclusive node with zero inbound edges is rejected with gateway_inbound_edges_invalid');

-- ── 20: reconvergence onto an End node from two distinct gateway
--    branches is fully supported (docs/70 ''Merge behavior'') —
--    publishes successfully. ────────────────────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '64900000-0000-0000-0000-000000000001','wfrv_reconverge','WFRV Reconverge','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw1","type":"gateway_exclusive","config":{}},{"key":"gw2","type":"gateway_exclusive","config":{}},{"key":"shared_end","type":"end","config":{"outcome_code":"done"}},{"key":"other_end","type":"end","config":{"outcome_code":"other"}}],"edges":[{"source":"start","target":"gw1","outcome":"started","priority":0,"default":false},{"source":"gw1","target":"gw2","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw1","target":"shared_end","outcome":"routed","priority":1,"default":true},{"source":"gw2","target":"shared_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"y","operator":"is_null"}},{"source":"gw2","target":"other_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  '64900000-1000-0000-0000-000000000003'))
INSERT INTO wfrv_ids SELECT 'reconv_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrv_ids WHERE name='reconv_v'),0,'64900000-1000-0000-0000-000000000004');
DO $$ BEGIN IF (SELECT status FROM workflow_definition_versions WHERE id=(SELECT id FROM wfrv_ids WHERE name='reconv_v')) <> 'published'
  THEN RAISE EXCEPTION 'expected reconvergence definition to publish'; END IF; END $$;
INSERT INTO wfrv_results VALUES (20,'two distinct gateway branches (from different gateway nodes) targeting the same End node publish successfully');

-- ── 21: the defensive capability_version_mismatch check at publish
--    time actually fires — verified by deliberately disabling the
--    version-immutability guard trigger for one UPDATE (the only way
--    to reach a mismatched row, since the trigger otherwise makes
--    capability_version immutable after insert), corrupting the
--    stored value, and confirming publish rejects it. ─────────────
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '64900000-0000-0000-0000-000000000001','wfrv_mismatch','WFRV Mismatch','opaque_case',
  :VALID_GATEWAY_PAYLOAD::jsonb, '64900000-1000-0000-0000-000000000005'))
INSERT INTO wfrv_ids SELECT 'mismatch_v', version_id FROM made;
RESET ROLE;
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definition_versions SET capability_version = 1 WHERE id = (SELECT id FROM wfrv_ids WHERE name='mismatch_v');
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64900000-0001-0000-0000-000000000001"}',false);
DO $$
BEGIN
  BEGIN
    PERFORM publish_workflow_definition_version((SELECT id FROM wfrv_ids WHERE name='mismatch_v'),0,gen_random_uuid());
    RAISE EXCEPTION 'expected capability_version_mismatch rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%capability_version_mismatch%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (21,'publish rejects a definition version whose stored capability_version no longer matches its payload schema_version');

-- ── Fixture for the variable-write scenarios: a plain inert instance
--    (variables are not tied to schema_version=2 — the write
--    foundation is generic). ────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64900000-0000-0000-0000-000000000001','wfrv_var_flow','WFRV Var Flow','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb, '64900000-1000-0000-0000-000000000006'))
INSERT INTO wfrv_ids SELECT 'var_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrv_ids WHERE name='var_v'),0,'64900000-1000-0000-0000-000000000007');
INSERT INTO wfrv_ids SELECT 'var_i', create_workflow_instance(
  (SELECT id FROM wfrv_ids WHERE name='var_v'),'opaque_case','64900000-2000-0000-0000-000000000001',
  '64900000-0000-0000-0000-000000000001','64900000-1000-0000-0000-000000000008',NULL);

-- ── 22: a first write of an instance variable succeeds, and an exact
--    replay (same idempotency key, same input) is a no-op returning
--    the same lock_version. ────────────────────────────────────────
SELECT * FROM set_workflow_instance_variable(
  (SELECT id FROM wfrv_ids WHERE name='var_i'),'priority_band','string','"urgent"'::jsonb,'restricted',
  '64900000-3000-0000-0000-000000000001');
DO $$
DECLARE v_lv1 BIGINT; v_lv2 BIGINT;
BEGIN
  SELECT lock_version INTO v_lv1 FROM workflow_variables
  WHERE instance_id = (SELECT id FROM wfrv_ids WHERE name='var_i') AND variable_name = 'priority_band';
  PERFORM set_workflow_instance_variable(
    (SELECT id FROM wfrv_ids WHERE name='var_i'),'priority_band','string','"urgent"'::jsonb,'restricted',
    '64900000-3000-0000-0000-000000000001');
  SELECT lock_version INTO v_lv2 FROM workflow_variables
  WHERE instance_id = (SELECT id FROM wfrv_ids WHERE name='var_i') AND variable_name = 'priority_band';
  IF v_lv1 <> 1 OR v_lv2 <> 1 THEN RAISE EXCEPTION 'expected lock_version=1 after create and after exact replay'; END IF;
END $$;
INSERT INTO wfrv_results VALUES (22,'a first instance-variable write succeeds and an exact idempotent replay is a no-op');

-- ── 23: the same idempotency key reused with different input fails
--    with the standard idempotency-mismatch contract. ─────────────
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'priority_band','string','"low"'::jsonb,'restricted',
      '64900000-3000-0000-0000-000000000001');
    RAISE EXCEPTION 'expected idempotency mismatch rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Idempotency key was already used with different input%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (23,'reusing a variable-write idempotency key with different input is rejected');

-- ── 24: a new idempotency key updates the value and increments
--    lock_version. ─────────────────────────────────────────────────
SELECT * FROM set_workflow_instance_variable(
  (SELECT id FROM wfrv_ids WHERE name='var_i'),'priority_band','string','"low"'::jsonb,'restricted',
  '64900000-3000-0000-0000-000000000002');
DO $$
BEGIN
  IF (SELECT lock_version FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrv_ids WHERE name='var_i') AND variable_name='priority_band') <> 2
     OR (SELECT variable_value FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrv_ids WHERE name='var_i') AND variable_name='priority_band') <> '"low"'::jsonb
  THEN RAISE EXCEPTION 'expected updated value and lock_version=2'; END IF;
END $$;
INSERT INTO wfrv_results VALUES (24,'a fresh idempotency key updates an existing variable and increments lock_version');

-- ── 25: a value that does not match its declared value_type is
--    rejected. ──────────────────────────────────────────────────────
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'bad_var','number','"not_a_number"'::jsonb,'restricted', gen_random_uuid());
    RAISE EXCEPTION 'expected type mismatch rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%does not match its declared type%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (25,'a variable value that does not match its declared value_type is rejected');

-- ── 26: value_type=''json'' accepts an arbitrary JSON object; a
--    value_type=''null'' write requires an actual JSON null value. ──
SELECT * FROM set_workflow_instance_variable(
  (SELECT id FROM wfrv_ids WHERE name='var_i'),'blob','json','{"a":1,"b":[true,false]}'::jsonb,'restricted', gen_random_uuid());
SELECT * FROM set_workflow_instance_variable(
  (SELECT id FROM wfrv_ids WHERE name='var_i'),'explicit_null','null','null'::jsonb,'restricted', gen_random_uuid());
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'bad_null','null','"not_null"'::jsonb,'restricted', gen_random_uuid());
    RAISE EXCEPTION 'expected null-type mismatch rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%does not match its declared type%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (26,'value_type=''json'' accepts an arbitrary JSON object and value_type=''null'' requires an actual JSON null');

RESET ROLE;

-- ── 27: a same-organization non-manager outsider cannot write an
--    instance variable. ────────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64900000-0001-0000-0000-000000000002"}',false);
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'x','boolean','true'::jsonb,'restricted', gen_random_uuid());
    RAISE EXCEPTION 'expected outsider rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not found or not manageable%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (27,'a same-organization non-manager outsider cannot write an instance variable');

-- ── 28: a cross-organization actor cannot write an instance
--    variable. ──────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims','{"sub":"64900000-0001-0000-0000-000000000003"}',false);
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'x','boolean','true'::jsonb,'restricted', gen_random_uuid());
    RAISE EXCEPTION 'expected cross-org rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not found or not manageable%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (28,'a cross-organization actor cannot write an instance variable');

-- ── 29: an instance variable cannot be set once the instance has
--    been cancelled (mutating commands require pending/active). ────
SELECT set_config('request.jwt.claims','{"sub":"64900000-0001-0000-0000-000000000001"}',false);
SELECT * FROM cancel_workflow_instance((SELECT id FROM wfrv_ids WHERE name='var_i'),0,gen_random_uuid(),'test_cancel');
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable(
      (SELECT id FROM wfrv_ids WHERE name='var_i'),'x','boolean','true'::jsonb,'restricted', gen_random_uuid());
    RAISE EXCEPTION 'expected cancelled-instance rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%pending or active%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrv_results VALUES (29,'an instance variable cannot be set once the instance is cancelled');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrv_results;
  IF v_count <> 29 THEN
    RAISE EXCEPTION 'Workflow routing validation foundation tests FAILED: expected 29, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow routing validation foundation tests PASSED: %/29', v_count;
END $$;

DROP FUNCTION wfrv_assert_create_rejected(TEXT, JSONB, UUID, TEXT);
