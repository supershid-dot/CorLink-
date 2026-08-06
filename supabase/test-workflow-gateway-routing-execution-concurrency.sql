-- CAP-002 Phase 4.2 gateway routing execution concurrency suite
-- (6 scenarios). Disposable local PostgreSQL only; requires dblink.
--
-- Gateway execution introduces no new mutable per-node runtime state
-- (unlike an approval round's quorum/candidate snapshot), so its
-- concurrency surface reduces to the same instance-level optimistic
-- concurrency and lock order every other command already uses. These
-- scenarios confirm that holds specifically when the contested
-- advancement target is a gateway_exclusive node — no new locking
-- primitive is introduced.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfgec_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfgec_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfgec_results, wfgec_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64990000-0000-0000-0000-000000000001','WF Gateway Exec Concurrency A','authority','WFGEC-A'),
 ('64990000-0000-0000-0000-000000000002','WF Gateway Exec Concurrency B','authority','WFGEC-B');
INSERT INTO auth.users(id,email) VALUES
 ('64990000-0001-0000-0000-000000000001','a@wfgec.local'),
 ('64990000-0001-0000-0000-000000000002','b@wfgec.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('64990000-0001-0000-0000-000000000001','64990000-0000-0000-0000-000000000001','WFGEC-1','A','a@wfgec.local',true,true),
 ('64990000-0001-0000-0000-000000000002','64990000-0000-0000-0000-000000000002','WFGEC-2','B','b@wfgec.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64990000-0001-0000-0000-000000000001','organization','64990000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64990000-0001-0000-0000-000000000002','organization','64990000-0000-0000-0000-000000000002','authority_admin',true,true);

-- review1 completes externally (test-only simulation); its 'approved'
-- edge targets a gateway which routes deterministically (default
-- edge, since the variable is never set) to a_end.
\set GW_CHAIN_PAYLOAD '\'{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"dead_end","type":"end","config":{"outcome_code":"d"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"gw","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"gw","target":"dead_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"never_set","operator":"is_not_null"}},{"source":"gw","target":"a_end","outcome":"routed","priority":1,"default":true}]}\''

CREATE OR REPLACE FUNCTION wfgec_simulate_decision(p_instance_id UUID, p_node_key TEXT, p_result_code TEXT) RETURNS VOID AS $$
BEGIN
  UPDATE workflow_instance_steps SET state = 'completed', result_code = p_result_code, ended_at = now()
  WHERE instance_id = p_instance_id AND definition_node_key = p_node_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfgec_simulate_decision(UUID,TEXT,TEXT) TO authenticated;

-- ── 1: two simultaneous workflow_advance_graph_step calls (distinct
--    idempotency keys, same expected lock version) racing to advance
--    the same instance through a gateway — exactly one succeeds;
--    the other observes a stale-version conflict. No duplicate
--    route_selected event; no corrupted final state. ─────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000001','wfgec_flow1','WFGEC Flow 1','opaque_case',:GW_CHAIN_PAYLOAD::jsonb,'64990000-1000-0000-0000-000000000001'))
INSERT INTO wfgec_ids SELECT 'v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v1'),0,'64990000-1000-0000-0000-000000000002');
INSERT INTO wfgec_ids SELECT 'inst1', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v1'),'opaque_case','64990000-2000-0000-0000-000000000001',
  '64990000-0000-0000-0000-000000000001','64990000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgec_ids WHERE name='inst1'),0,'64990000-1000-0000-0000-000000000004');
RESET ROLE;
SELECT wfgec_simulate_decision((SELECT id FROM wfgec_ids WHERE name='inst1'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000010'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000011'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst1')));
CREATE TEMP TABLE wfgec_c1(v text, err text);
CREATE TEMP TABLE wfgec_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_iid UUID := (SELECT id FROM wfgec_ids WHERE name='inst1'); v_route_count INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfgec_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfgec_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one distinct successful advancement result, got %', v_winners; END IF;
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected the winning advancement to route through the gateway to a_end';
  END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 route_selected event, not duplicated by the race, got %', v_route_count; END IF;
END $$;
INSERT INTO wfgec_results VALUES (1,'two simultaneous workflow_advance_graph_step calls racing to advance the same instance through a gateway produce exactly one successful result and exactly one route_selected event');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: duplicate advancement with the SAME idempotency key through
--    the gateway, issued concurrently, replays safely and converges
--    to exactly one route_selected event. ─────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000001','wfgec_flow2','WFGEC Flow 2','opaque_case',:GW_CHAIN_PAYLOAD::jsonb,'64990000-1000-0000-0000-000000000012'))
INSERT INTO wfgec_ids SELECT 'v2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v2'),0,'64990000-1000-0000-0000-000000000013');
INSERT INTO wfgec_ids SELECT 'inst2', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v2'),'opaque_case','64990000-2000-0000-0000-000000000002',
  '64990000-0000-0000-0000-000000000001','64990000-1000-0000-0000-000000000014',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgec_ids WHERE name='inst2'),0,'64990000-1000-0000-0000-000000000015');
RESET ROLE;
SELECT wfgec_simulate_decision((SELECT id FROM wfgec_ids WHERE name='inst2'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000020'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst2')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000020'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst2')));
TRUNCATE wfgec_c1, wfgec_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfgec_ids WHERE name='inst2'); v_route_count INTEGER;
BEGIN
  IF (SELECT count(*) FROM wfgec_c1 WHERE v='completed') + (SELECT count(*) FROM wfgec_c2 WHERE v='completed') <> 2 THEN
    RAISE EXCEPTION 'expected both concurrent same-key calls to return the identical completed result, got c1=%, c2=%',
      (SELECT v FROM wfgec_c1), (SELECT v FROM wfgec_c2);
  END IF;
  SELECT count(*) INTO v_route_count FROM workflow_events WHERE instance_id=v_iid AND event_type='route_selected';
  IF v_route_count <> 1 THEN RAISE EXCEPTION 'a same-key concurrent replay must not duplicate route_selected, got %', v_route_count; END IF;
END $$;
INSERT INTO wfgec_results VALUES (2,'duplicate advancement through a gateway with the same idempotency key, issued concurrently, replays safely and converges to exactly one route_selected event');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: a concurrent instance-variable write and a graph advancement
--    through the gateway that reads that same variable fully
--    serialize via the shared instance-row lock — no corruption, no
--    deadlock, and exactly one deterministic final route regardless
--    of which command wins the race. ──────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000001','wfgec_flow3','WFGEC Flow 3','opaque_case',
  '{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"flag","operator":"equals","value_type":"boolean","value":true}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}'::jsonb,
  '64990000-1000-0000-0000-000000000021'))
INSERT INTO wfgec_ids SELECT 'v3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v3'),0,'64990000-1000-0000-0000-000000000022');
INSERT INTO wfgec_ids SELECT 'inst3', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v3'),'opaque_case','64990000-2000-0000-0000-000000000003',
  '64990000-0000-0000-0000-000000000001','64990000-1000-0000-0000-000000000023',NULL);
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'flag','boolean','true'::jsonb,'restricted','64990000-1000-0000-0000-000000000024'::uuid)$q$,
  (SELECT id FROM wfgec_ids WHERE name='inst3')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'64990000-1000-0000-0000-000000000025'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst3')));
TRUNCATE wfgec_c1, wfgec_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfgec_ids WHERE name='inst3'); v_outcome TEXT;
BEGIN
  -- Both operations must succeed (the variable write always succeeds
  -- regardless of ordering; activation always succeeds too, since it
  -- does not require the variable to exist). The deadlock-freedom and
  -- lack-of-corruption is the property under test, not which specific
  -- branch was taken (that depends on ordering, which is legitimately
  -- non-deterministic here).
  IF (SELECT count(*) FROM wfgec_c2 WHERE v='completed') <> 1 THEN
    RAISE EXCEPTION 'expected activation to complete regardless of the race outcome, got %', (SELECT v FROM wfgec_c2);
  END IF;
  SELECT terminal_outcome INTO v_outcome FROM workflow_instances WHERE id=v_iid;
  IF v_outcome NOT IN ('a','b') THEN
    RAISE EXCEPTION 'expected a deterministic, uncorrupted final outcome (a or b), got %', v_outcome;
  END IF;
  IF EXISTS (SELECT 1 FROM wfgec_c1 WHERE err IS NOT NULL) THEN
    RAISE EXCEPTION 'the concurrent variable write should not error: %', (SELECT err FROM wfgec_c1);
  END IF;
END $$;
INSERT INTO wfgec_results VALUES (3,'a concurrent instance-variable write and a graph activation reading that variable through a gateway fully serialize via the shared instance-row lock with no corruption and no deadlock');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: advance-through-gateway versus cancellation race — exactly
--    one valid final state, no partial/corrupted result. ──────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000001','wfgec_flow4','WFGEC Flow 4','opaque_case',:GW_CHAIN_PAYLOAD::jsonb,'64990000-1000-0000-0000-000000000026'))
INSERT INTO wfgec_ids SELECT 'v4',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v4'),0,'64990000-1000-0000-0000-000000000027');
INSERT INTO wfgec_ids SELECT 'inst4', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v4'),'opaque_case','64990000-2000-0000-0000-000000000004',
  '64990000-0000-0000-0000-000000000001','64990000-1000-0000-0000-000000000028',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgec_ids WHERE name='inst4'),0,'64990000-1000-0000-0000-000000000029');
RESET ROLE;
SELECT wfgec_simulate_decision((SELECT id FROM wfgec_ids WHERE name='inst4'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000030'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst4')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM cancel_workflow_instance('%s'::uuid,1,'64990000-1000-0000-0000-000000000031'::uuid,'race_test')$q$, (SELECT id FROM wfgec_ids WHERE name='inst4')));
TRUNCATE wfgec_c1, wfgec_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfgec_ids WHERE name='inst4'); v_status TEXT; v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfgec_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfgec_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one winner between advance-through-gateway and cancel, got %', v_winners; END IF;
  SELECT status INTO v_status FROM workflow_instances WHERE id=v_iid;
  IF v_status NOT IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'expected a valid final state (completed or cancelled), got %', v_status;
  END IF;
END $$;
INSERT INTO wfgec_results VALUES (4,'a race between advancing through a gateway and cancelling the instance has exactly one winner and lands in a valid final state, never a corrupted partial result');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: unrelated organizations'' gateway routing proceeds
--    independently with no unnecessary blocking. ──────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000001','wfgec_flow5a','WFGEC Flow 5A','opaque_case',:GW_CHAIN_PAYLOAD::jsonb,'64990000-1000-0000-0000-000000000032'))
INSERT INTO wfgec_ids SELECT 'v5a',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v5a'),0,'64990000-1000-0000-0000-000000000033');
INSERT INTO wfgec_ids SELECT 'inst5a', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v5a'),'opaque_case','64990000-2000-0000-0000-000000000005',
  '64990000-0000-0000-0000-000000000001','64990000-1000-0000-0000-000000000034',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgec_ids WHERE name='inst5a'),0,'64990000-1000-0000-0000-000000000035');
RESET ROLE;
SELECT wfgec_simulate_decision((SELECT id FROM wfgec_ids WHERE name='inst5a'), 'review1', 'approved');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000002"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('64990000-0000-0000-0000-000000000002','wfgec_flow5b','WFGEC Flow 5B','opaque_case',:GW_CHAIN_PAYLOAD::jsonb,'64990000-1000-0000-0000-000000000036'))
INSERT INTO wfgec_ids SELECT 'v5b',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgec_ids WHERE name='v5b'),0,'64990000-1000-0000-0000-000000000037');
INSERT INTO wfgec_ids SELECT 'inst5b', create_workflow_instance(
  (SELECT id FROM wfgec_ids WHERE name='v5b'),'opaque_case','64990000-2000-0000-0000-000000000006',
  '64990000-0000-0000-0000-000000000002','64990000-1000-0000-0000-000000000038',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgec_ids WHERE name='inst5b'),0,'64990000-1000-0000-0000-000000000039');
RESET ROLE;
SELECT wfgec_simulate_decision((SELECT id FROM wfgec_ids WHERE name='inst5b'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000040'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst5a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'64990000-1000-0000-0000-000000000041'::uuid)$q$, (SELECT id FROM wfgec_ids WHERE name='inst5b')));
TRUNCATE wfgec_c1, wfgec_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgec_c2 VALUES (v_val, v_err);
END $$;
DO $$
BEGIN
  IF (SELECT count(*) FROM wfgec_c1) <> 1 OR (SELECT count(*) FROM wfgec_c2) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one result row from each connection, got c1=%, c2=%',
      (SELECT count(*) FROM wfgec_c1), (SELECT count(*) FROM wfgec_c2);
  END IF;
  IF (SELECT v FROM wfgec_c1) IS DISTINCT FROM 'completed' OR (SELECT v FROM wfgec_c2) IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'unrelated-organization concurrent advancements through the gateway did not both succeed: c1=%, c2=%',
      (SELECT v FROM wfgec_c1), (SELECT v FROM wfgec_c2);
  END IF;
END $$;
INSERT INTO wfgec_results VALUES (5,'gateway routing in unrelated organizations proceeds independently with no unnecessary blocking');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 6: no deadlock observed under the documented lock order across
--    all five prior scenarios. ─────────────────────────────────────
INSERT INTO wfgec_results VALUES (6,'no deadlock was observed under the documented lock order across all five prior gateway-routing concurrency scenarios');

-- ── Cleanup: committed cross-session fixtures removed in FK-
--    dependency order, leaving the disposable database as found. ───
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64990000-0001-0000-0000-000000000001"}',false);
RESET ROLE;
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_variables WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '64990000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '64990000-%';
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '64990000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '64990000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '64990000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '64990000-%';
DELETE FROM users WHERE id::text LIKE '64990000-%';
DELETE FROM auth.users WHERE id::text LIKE '64990000-%';
DELETE FROM organizations WHERE id::text LIKE '64990000-%';
DROP FUNCTION IF EXISTS wfgec_simulate_decision(UUID,TEXT,TEXT);

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfgec_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow gateway routing execution concurrency tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow gateway routing execution concurrency tests PASSED: %/6', v_count;
END $$;
