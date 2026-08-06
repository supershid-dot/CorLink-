-- CAP-002 Phase 4.2 gateway routing execution — behavioral suite.
-- Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

CREATE TEMP TABLE wfge_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfge_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfge_results, wfge_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64970000-0000-0000-0000-000000000001','WF Gateway Exec A','authority','WFGE-A'),
 ('64970000-0000-0000-0000-000000000002','WF Gateway Exec B','authority','WFGE-B');
INSERT INTO auth.users(id,email) VALUES
 ('64970000-0001-0000-0000-000000000001','admin@wfge.local'),
 ('64970000-0001-0000-0000-000000000002','sup1@wfge.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('64970000-0001-0000-0000-000000000001','64970000-0000-0000-0000-000000000001','WFGE-1','Admin','admin@wfge.local',true),
 ('64970000-0001-0000-0000-000000000002','64970000-0000-0000-0000-000000000001','WFGE-2','Sup1','sup1@wfge.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64970000-0001-0000-0000-000000000001','organization','64970000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64970000-0001-0000-0000-000000000002','organization','64970000-0000-0000-0000-000000000001','supervisor',true,true);

-- Helper: assert contiguous, gap-free event sequencing for an
-- instance, matching every prior phase's established assertion
-- pattern.
CREATE OR REPLACE FUNCTION wfge_assert_contiguous(p_instance_id UUID, p_label TEXT) RETURNS VOID AS $$
DECLARE v_count INTEGER; v_max BIGINT;
BEGIN
  SELECT count(*), max(event_sequence) INTO v_count, v_max FROM workflow_events WHERE instance_id = p_instance_id;
  IF v_count <> v_max THEN
    RAISE EXCEPTION '% : event sequence not contiguous (count=%, max=%)', p_label, v_count, v_max;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfge_assert_contiguous(UUID, TEXT) TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64970000-0001-0000-0000-000000000001"}',false);

-- Helper macro-payload: start -> gw -> {matched_end | default_end}.
-- One reusable shape parameterized only by the condition, built
-- per-scenario below via string substitution since payloads are
-- literal JSON.
\set SIMPLE_GW_TEMPLATE '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"matched_end","type":"end","config":{"outcome_code":"matched"}},{"key":"default_end","type":"end","config":{"outcome_code":"defaulted"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"matched_end","outcome":"routed","priority":0,"default":false,"condition":__COND__},{"source":"gw","target":"default_end","outcome":"routed","priority":1,"default":true}]}'

-- ── 1: the very first node after start can itself be a gateway;
--    a matching condition (equals/string) routes to the matched
--    branch and the instance completes synchronously. ─────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s1','WFGE S1','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__',
    '{"source":"instance_variable","variable_name":"priority_band","operator":"equals","value_type":"string","value":"urgent"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v1', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v1'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i1', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v1'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i1'),'priority_band','string','"urgent"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i1'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i1');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'matched' THEN
    RAISE EXCEPTION 'expected a matching gateway condition to route to the matched End';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected') THEN
    RAISE EXCEPTION 'expected a route_selected event';
  END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i1'), 'scenario 1');
INSERT INTO wfge_results VALUES (1,'a gateway as the very first executable node routes via a matching equals/string condition and completes synchronously');

-- ── 2: no variable set — falls through to the mandatory default
--    branch. used_default=true recorded on the event. ─────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s2','WFGE S2','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__',
    '{"source":"instance_variable","variable_name":"priority_band","operator":"equals","value_type":"string","value":"urgent"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v2', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v2'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i2', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v2'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i2'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i2'); v_meta JSONB;
BEGIN
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'defaulted' THEN
    RAISE EXCEPTION 'expected an undefined variable to fall through to the default branch';
  END IF;
  SELECT metadata INTO v_meta FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF (v_meta ->> 'used_default')::BOOLEAN IS NOT TRUE THEN
    RAISE EXCEPTION 'expected used_default=true on the route_selected event';
  END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i2'), 'scenario 2');
INSERT INTO wfge_results VALUES (2,'an undefined instance variable falls through to the mandatory default branch, recorded as used_default=true');

-- ── 3: priority ordering — two non-default branches both structurally
--    ''could'' match, but only the lower-priority one is evaluated
--    first and wins; the higher-priority (later-evaluated) branch is
--    never even reached. ─────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s3','WFGE S3','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"low_end","type":"end","config":{"outcome_code":"low"}},{"key":"high_end","type":"end","config":{"outcome_code":"high"}},{"key":"default_end","type":"end","config":{"outcome_code":"defaulted"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"low_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"score","operator":"greater_than","value_type":"number","value":0}},{"source":"gw","target":"high_end","outcome":"routed","priority":1,"default":false,"condition":{"source":"instance_variable","variable_name":"score","operator":"greater_than","value_type":"number","value":50}},{"source":"gw","target":"default_end","outcome":"routed","priority":2,"default":true}]}'::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v3', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v3'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i3', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v3'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i3'),'score','number','100'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i3'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i3'); v_meta JSONB;
BEGIN
  -- score=100 satisfies BOTH low (>0) and high (>50) conditions, but
  -- priority 0 (low) is evaluated first and wins.
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'low' THEN
    RAISE EXCEPTION 'expected the lower-priority (earlier-evaluated) matching branch to win, not high';
  END IF;
  SELECT metadata INTO v_meta FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF jsonb_array_length(v_meta -> 'evaluated_conditions') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one evaluated condition (priority 1''s branch never reached)';
  END IF;
END $$;
INSERT INTO wfge_results VALUES (3,'ascending-priority evaluation stops at the first match; a later, also-matching branch is never evaluated');

-- ── 4: is_null matches an undefined variable (the deliberate
--    carve-out from the ''undefined=false'' rule). ─────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s4','WFGE S4','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"absent_var","operator":"is_null"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v4', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v4'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i4', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v4'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i4'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i4')) <> 'matched'
  THEN RAISE EXCEPTION 'expected is_null to match an undefined variable'; END IF; END $$;
INSERT INTO wfge_results VALUES (4,'is_null matches an undefined instance variable');

-- ── 5: is_not_null does NOT match an undefined variable (falls to
--    default). ──────────────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s5','WFGE S5','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"absent_var","operator":"is_not_null"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v5', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v5'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i5', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v5'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i5'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i5')) <> 'defaulted'
  THEN RAISE EXCEPTION 'expected is_not_null to NOT match an undefined variable'; END IF; END $$;
INSERT INTO wfge_results VALUES (5,'is_not_null does not match an undefined instance variable, falling through to the default branch');

-- ── 6: is_not_null matches a variable that IS set. ─────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s6','WFGE S6','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"x","operator":"is_not_null"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v6', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v6'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i6', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v6'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i6'),'x','boolean','true'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i6'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i6')) <> 'matched'
  THEN RAISE EXCEPTION 'expected is_not_null to match a defined variable'; END IF; END $$;
INSERT INTO wfge_results VALUES (6,'is_not_null matches a defined instance variable');

-- ── 7: not_equals (string). ─────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s7','WFGE S7','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"status","operator":"not_equals","value_type":"string","value":"closed"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v7', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v7'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i7', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v7'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i7'),'status','string','"open"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i7'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i7')) <> 'matched'
  THEN RAISE EXCEPTION 'expected not_equals(status,closed) to match status=open'; END IF; END $$;
INSERT INTO wfge_results VALUES (7,'not_equals (string) matches when the stored value differs from the literal');

-- ── 8: in (number). ──────────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s8','WFGE S8','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"tier","operator":"in","value_type":"number","value":[1,2,3]}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v8', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v8'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i8', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v8'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i8'),'tier','number','2'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i8'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i8')) <> 'matched'
  THEN RAISE EXCEPTION 'expected in([1,2,3]) to match tier=2'; END IF; END $$;
INSERT INTO wfge_results VALUES (8,'in (number) matches when the stored value is a member of the literal array');

-- ── 9: not_in (string). ──────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s9','WFGE S9','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"region","operator":"not_in","value_type":"string","value":["eu","apac"]}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v9', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v9'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i9', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v9'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i9'),'region','string','"us"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i9'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i9')) <> 'matched'
  THEN RAISE EXCEPTION 'expected not_in([eu,apac]) to match region=us'; END IF; END $$;
INSERT INTO wfge_results VALUES (9,'not_in (string) matches when the stored value is absent from the literal array');

-- ── 10: less_than / less_than_or_equal / greater_than_or_equal exact
--     boundary behavior (number). ───────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s10','WFGE S10','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"n","operator":"less_than_or_equal","value_type":"number","value":10}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v10', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v10'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i10', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v10'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i10'),'n','number','10'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i10'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i10')) <> 'matched'
  THEN RAISE EXCEPTION 'expected less_than_or_equal(10) to match n=10 (exact boundary)'; END IF; END $$;
INSERT INTO wfge_results VALUES (10,'less_than_or_equal matches at the exact numeric boundary');

-- ── 11: date comparison. ────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s11','WFGE S11','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"deadline","operator":"greater_than","value_type":"date","value":"2026-01-01"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v11', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v11'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i11', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v11'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i11'),'deadline','date','"2026-06-15"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i11'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i11')) <> 'matched'
  THEN RAISE EXCEPTION 'expected date comparison to match'; END IF; END $$;
INSERT INTO wfge_results VALUES (11,'greater_than (date) correctly compares calendar dates');

-- ── 12: timestamp comparison. ───────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s12','WFGE S12','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"submitted_at","operator":"less_than","value_type":"timestamp","value":"2026-01-01T00:00:00Z"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v12', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v12'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i12', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v12'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i12'),'submitted_at','timestamp','"2025-06-15T10:30:00Z"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i12'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i12')) <> 'matched'
  THEN RAISE EXCEPTION 'expected timestamp comparison to match'; END IF; END $$;
INSERT INTO wfge_results VALUES (12,'less_than (timestamp) correctly compares timestamptz values');

-- ── 13: uuid equals. ────────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s13','WFGE S13','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"category_id","operator":"equals","value_type":"uuid","value":"11111111-1111-1111-1111-111111111111"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v13', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v13'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i13', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v13'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i13'),'category_id','uuid','"11111111-1111-1111-1111-111111111111"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i13'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i13')) <> 'matched'
  THEN RAISE EXCEPTION 'expected uuid equals to match'; END IF; END $$;
INSERT INTO wfge_results VALUES (13,'equals (uuid) matches an identical UUID literal');

-- ── 14: boolean equals. ─────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s14','WFGE S14','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"flag","operator":"equals","value_type":"boolean","value":true}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v14', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v14'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i14', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v14'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i14'),'flag','boolean','true'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i14'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i14')) <> 'matched'
  THEN RAISE EXCEPTION 'expected boolean equals to match'; END IF; END $$;
INSERT INTO wfge_results VALUES (14,'equals (boolean) matches an identical boolean literal');

-- ── 15: a type-mismatched variable (declared string, stored as
--     number) never matches — falls through to default. ───────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s15','WFGE S15','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"mismatched","operator":"equals","value_type":"string","value":"5"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v15', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v15'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i15', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v15'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i15'),'mismatched','number','5'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i15'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i15')) <> 'defaulted'
  THEN RAISE EXCEPTION 'expected a value_type mismatch to never match, falling through to default'; END IF; END $$;
INSERT INTO wfge_results VALUES (15,'a variable whose stored value_type does not match the condition''s declared value_type never matches (deterministic false, not an error)');

-- ── 16: an explicit-null variable (value_type=''null'') never
--     matches a non-null-testing operator. ─────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s16','WFGE S16','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__', '{"source":"instance_variable","variable_name":"explicit_null","operator":"equals","value_type":"string","value":"x"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v16', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v16'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i16', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v16'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i16'),'explicit_null','null','null'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i16'),0,gen_random_uuid());
DO $$ BEGIN IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i16')) <> 'defaulted'
  THEN RAISE EXCEPTION 'expected an explicit-null variable to never match equals, falling through to default'; END IF; END $$;
INSERT INTO wfge_results VALUES (16,'an explicit-null variable never matches a non-null-testing operator, falling through to default');

-- ── 17: route_selected never leaks the raw variable value into event
--     metadata — only priority/matched booleans. ──────────────────
DO $$
DECLARE v_meta JSONB;
BEGIN
  SELECT metadata INTO v_meta FROM workflow_events WHERE instance_id=(SELECT id FROM wfge_ids WHERE name='i1') AND event_type='route_selected';
  IF v_meta::TEXT ILIKE '%urgent%' THEN
    RAISE EXCEPTION 'route_selected metadata leaked the raw condition value into the event ledger';
  END IF;
  IF NOT (v_meta ? 'evaluated_conditions')
     OR jsonb_typeof(v_meta -> 'evaluated_conditions' -> 0 -> 'matched') <> 'boolean' THEN
    RAISE EXCEPTION 'expected evaluated_conditions to contain only boolean match results';
  END IF;
END $$;
INSERT INTO wfge_results VALUES (17,'route_selected event metadata never contains raw variable/condition literal values, only priority/matched booleans');

-- ── 18: a multi-hop chain of three consecutive gateways resolves
--     synchronously in one command, with the correct final outcome. ─
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s18','WFGE S18','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw1","type":"gateway_exclusive","config":{}},{"key":"gw2","type":"gateway_exclusive","config":{}},{"key":"gw3","type":"gateway_exclusive","config":{}},{"key":"final_end","type":"end","config":{"outcome_code":"reached"}},{"key":"dead1","type":"end","config":{"outcome_code":"d1"}},{"key":"dead2","type":"end","config":{"outcome_code":"d2"}},{"key":"dead3","type":"end","config":{"outcome_code":"d3"}}],"edges":[{"source":"start","target":"gw1","outcome":"started","priority":0,"default":false},{"source":"gw1","target":"dead1","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set_1","operator":"is_not_null"}},{"source":"gw1","target":"gw2","outcome":"routed","priority":1,"default":true},{"source":"gw2","target":"dead2","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set_2","operator":"is_not_null"}},{"source":"gw2","target":"gw3","outcome":"routed","priority":1,"default":true},{"source":"gw3","target":"dead3","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set_3","operator":"is_not_null"}},{"source":"gw3","target":"final_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v18', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v18'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i18', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v18'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i18'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i18');
BEGIN
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'reached' THEN
    RAISE EXCEPTION 'expected a 3-hop consecutive gateway chain to resolve synchronously to final_end';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected') <> 3 THEN
    RAISE EXCEPTION 'expected exactly 3 route_selected events for the 3-hop chain';
  END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i18'), 'scenario 18');
INSERT INTO wfge_results VALUES (18,'a 3-hop consecutive gateway chain resolves synchronously in one command with 3 route_selected events and correct final outcome');

-- ── 19: a gateway routes into a real approval node (nonzero
--     electorate) — the instance stops, waiting, with a real open
--     round; instance_started''s own metadata correctly reflects
--     ''active'', not a terminal outcome (the peek walked through the
--     gateway hop but correctly stopped at the approval wait). ─────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s19','WFGE S19','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"dead_end","type":"end","config":{"outcome_code":"d"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"dead_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set","operator":"is_not_null"}},{"source":"gw","target":"review","outcome":"routed","priority":1,"default":true},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v19', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v19'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i19', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v19'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i19'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i19'); v_meta JSONB;
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'active' THEN
    RAISE EXCEPTION 'expected the instance to be active, waiting on a real approval round after routing through the gateway';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid AND state='open') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one open approval round after routing through the gateway';
  END IF;
  SELECT metadata INTO v_meta FROM workflow_events WHERE instance_id=v_iid AND event_type='instance_started';
  IF (v_meta ->> 'new_status') <> 'active' THEN
    RAISE EXCEPTION 'expected instance_started''s own peeked metadata to correctly show active (not a terminal outcome) since the peek walked through the gateway to a real approval wait';
  END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i19'), 'scenario 19');
INSERT INTO wfge_results VALUES (19,'a gateway routing into a real (nonzero-electorate) approval node correctly stops and waits, with accurate peeked replay metadata');

-- ── 20: approving the round from scenario 19 advances through the
--     already-taken gateway route to End, exercising
--     decide_workflow_work_item -> peek -> enter reuse (no changes
--     needed to decide_workflow_work_item itself). ─────────────────
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i19'); v_wi UUID; v_lv BIGINT;
BEGIN
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to='64970000-0001-0000-0000-000000000001';
  SELECT lock_version INTO v_lv FROM workflow_instances WHERE id=v_iid;
  PERFORM decide_workflow_work_item(v_wi, 'approve', v_lv, 0, gen_random_uuid());
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected approval to complete the instance via the End reached through the already-taken gateway route';
  END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i19'), 'scenario 20');
INSERT INTO wfge_results VALUES (20,'decide_workflow_work_item advances a decided round through graph state already routed via a gateway, with no change needed to decide_workflow_work_item itself');

-- ── 21: reconvergence executes correctly end-to-end — two distinct
--     upstream gateway branches both target the same downstream
--     gateway node; both execution paths are exercised and both
--     reach the correct final outcome. ─────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s21','WFGE S21','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw1","type":"gateway_exclusive","config":{}},{"key":"gw2","type":"gateway_exclusive","config":{}},{"key":"shared","type":"gateway_exclusive","config":{}},{"key":"shared_end","type":"end","config":{"outcome_code":"shared_reached"}}],"edges":[{"source":"start","target":"gw1","outcome":"started","priority":0,"default":false},{"source":"gw1","target":"shared","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"path","operator":"equals","value_type":"string","value":"one"}},{"source":"gw1","target":"gw2","outcome":"routed","priority":1,"default":true},{"source":"gw2","target":"shared","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set_gw2","operator":"is_not_null"}},{"source":"gw2","target":"shared","outcome":"routed","priority":1,"default":true},{"source":"shared","target":"shared_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set_shared","operator":"is_not_null"}},{"source":"shared","target":"shared_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v21', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v21'),0,gen_random_uuid());
-- Path A: gw1 -> shared directly (condition matches).
INSERT INTO wfge_ids SELECT 'i21a', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v21'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i21a'),'path','string','"one"'::jsonb,'restricted',gen_random_uuid());
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i21a'),0,gen_random_uuid());
-- Path B: gw1 -> gw2 (default) -> shared.
INSERT INTO wfge_ids SELECT 'i21b', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v21'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i21b'),0,gen_random_uuid());
DO $$
BEGIN
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i21a')) <> 'shared_reached' THEN
    RAISE EXCEPTION 'expected path A (direct gw1->shared) to reach shared_end';
  END IF;
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=(SELECT id FROM wfge_ids WHERE name='i21b')) <> 'shared_reached' THEN
    RAISE EXCEPTION 'expected path B (gw1->gw2->shared) to also reach shared_end';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wfge_ids WHERE name='i21a') AND event_type='route_selected') <> 2 THEN
    RAISE EXCEPTION 'expected path A to take exactly 2 gateway hops (gw1, shared)';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wfge_ids WHERE name='i21b') AND event_type='route_selected') <> 3 THEN
    RAISE EXCEPTION 'expected path B to take exactly 3 gateway hops (gw1, gw2, shared)';
  END IF;
END $$;
INSERT INTO wfge_results VALUES (21,'reconvergence executes correctly end-to-end: two distinct upstream gateway paths both reach the same downstream gateway node and the same final outcome');

-- ── 22: activation replay — the same start idempotency key replayed
--     on a fresh instance whose first executable node is itself a
--     gateway returns the identical result with no duplicate
--     route_selected event. ────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s22','WFGE S22','opaque_case',
  replace(:'SIMPLE_GW_TEMPLATE', '__COND__',
    '{"source":"instance_variable","variable_name":"priority_band","operator":"equals","value_type":"string","value":"urgent"}')::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v22', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v22'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i22', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v22'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT set_workflow_instance_variable((SELECT id FROM wfge_ids WHERE name='i22'),'priority_band','string','"urgent"'::jsonb,'restricted',gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i22'); v_key UUID := gen_random_uuid();
  v_r1 RECORD; v_route_count INTEGER;
BEGIN
  SELECT * INTO v_r1 FROM start_workflow_instance(v_iid, 0, v_key);
  IF v_r1.replayed IS DISTINCT FROM FALSE THEN RAISE EXCEPTION 'expected the first start call to not be a replay'; END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 route_selected event before replay'; END IF;

  -- Exact replay: identical idempotency key, identical (only) input.
  SELECT * INTO v_r1 FROM start_workflow_instance(v_iid, 0, v_key);
  IF v_r1.replayed IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'expected the replay flag to be true'; END IF;
  IF v_r1.terminal_outcome <> 'matched' THEN RAISE EXCEPTION 'expected the replay to return the identical original outcome'; END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'replay must not create a duplicate route_selected event, got %', v_route_count; END IF;
END $$;
INSERT INTO wfge_results VALUES (22,'an exact activation-idempotency-key replay through a first-node gateway converges to the identical result with no duplicate route_selected event');

-- ── 23: advancing an already-active instance via
--     workflow_advance_graph_step through a gateway, replayed with
--     the same idempotency key, converges to the identical result
--     with no duplicate route_selected event. ─────────────────────
WITH made AS (SELECT * FROM create_workflow_definition(
  '64970000-0000-0000-0000-000000000001','wfge_s23','WFGE S23','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"dead_end","type":"end","config":{"outcome_code":"d"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"gw","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"gw","target":"dead_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set","operator":"is_not_null"}},{"source":"gw","target":"a_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  gen_random_uuid()))
INSERT INTO wfge_ids SELECT 'v23', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfge_ids WHERE name='v23'),0,gen_random_uuid());
INSERT INTO wfge_ids SELECT 'i23', create_workflow_instance((SELECT id FROM wfge_ids WHERE name='v23'),'opaque_case',gen_random_uuid(),'64970000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfge_ids WHERE name='i23'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfge_ids WHERE name='i23'); v_wi UUID; v_lv BIGINT; v_key UUID := gen_random_uuid();
  v_r1 RECORD; v_r2 RECORD; v_route_count INTEGER;
BEGIN
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to='64970000-0001-0000-0000-000000000001';
  SELECT lock_version INTO v_lv FROM workflow_instances WHERE id=v_iid;
  PERFORM decide_workflow_work_item(v_wi, 'approve', v_lv, 0, v_key);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed' OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected the decision to route through the gateway to a_end';
  END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 route_selected event before replay'; END IF;

  -- Exact replay with the identical idempotency key and identical input.
  SELECT * INTO v_r1 FROM decide_workflow_work_item(v_wi, 'approve', v_lv, 0, v_key);
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'replay must not create a duplicate route_selected event, got %', v_route_count; END IF;
  IF v_r1.replayed IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'expected the replay flag to be true'; END IF;
END $$;
SELECT wfge_assert_contiguous((SELECT id FROM wfge_ids WHERE name='i23'), 'scenario 23');
INSERT INTO wfge_results VALUES (23,'an exact idempotency-key replay of a decision that advances through a gateway converges to the identical result with no duplicate route_selected event');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfge_results;
  IF v_count <> 23 THEN
    RAISE EXCEPTION 'Workflow gateway routing execution tests FAILED: expected 23, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow gateway routing execution behavioral tests PASSED: %/23', v_count;
END $$;

DROP FUNCTION wfge_assert_contiguous(UUID, TEXT);
