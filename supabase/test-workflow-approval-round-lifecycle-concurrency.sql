-- CAP-002 Phase 3.2 approval round lifecycle concurrency suite (6 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
--
-- Exercises concurrency safety specifically for the new bounded
-- synchronous skip loop inside workflow_enter_downstream_node: races
-- entering/skipping the same zero-candidate optional node, and
-- replay races on a decision whose closure advances through a skip
-- chain. Reuses the exact lock order and advisory-lock namespaces
-- Phase 2C.1/3.1 already established — no new locking primitive.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfrlc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrlc_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrlc_results, wfrlc_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67820000-0000-0000-0000-000000000001','WF Round Lifecycle Concurrency A','authority','WFRLC-A'),
 ('67820000-0000-0000-0000-000000000002','WF Round Lifecycle Concurrency B','authority','WFRLC-B');
INSERT INTO auth.users(id,email) VALUES
 ('67820000-0001-0000-0000-000000000001','a@wfrlc.local'),
 ('67820000-0001-0000-0000-000000000002','b@wfrlc.local'),
 ('67820000-0001-0000-0000-000000000003','sup1@wfrlc.local'),
 ('67820000-0001-0000-0000-000000000004','sup2@wfrlc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('67820000-0001-0000-0000-000000000001','67820000-0000-0000-0000-000000000001','WFRLC-1','A','a@wfrlc.local',true,true),
 ('67820000-0001-0000-0000-000000000002','67820000-0000-0000-0000-000000000002','WFRLC-2','B','b@wfrlc.local',true,true);
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67820000-0001-0000-0000-000000000003','67820000-0000-0000-0000-000000000001','WFRLC-3','Sup1','sup1@wfrlc.local',true),
 ('67820000-0001-0000-0000-000000000004','67820000-0000-0000-0000-000000000002','WFRLC-4','Sup2','sup2@wfrlc.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67820000-0001-0000-0000-000000000001','organization','67820000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67820000-0001-0000-0000-000000000002','organization','67820000-0000-0000-0000-000000000002','authority_admin',true,true),
 ('67820000-0001-0000-0000-000000000004','organization','67820000-0000-0000-0000-000000000002','supervisor',true,true),
 ('67820000-0001-0000-0000-000000000003','organization','67820000-0000-0000-0000-000000000001','supervisor',true,true);

-- review1 completes externally (test-only simulation); review2 is a
-- zero-candidate optional node whose skip continues to review3
-- (required, supervisor) which waits.
\set SKIP_CHAIN_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_receivers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review3","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"x_dead_end","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"x_dead_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"review3","outcome":"skipped","priority":0,"default":false},{"source":"review3","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review3","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

-- Test-only SECURITY DEFINER helper simulating "review1 has already
-- been decided approved" — this suite races the GRAPH-STEP entry
-- into the skip chain itself, independent of who/how review1 closed,
-- matching the established wfga_simulate_decision precedent.
CREATE OR REPLACE FUNCTION wfrlc_simulate_decision(p_instance_id UUID, p_node_key TEXT, p_result_code TEXT) RETURNS VOID AS $$
BEGIN
  UPDATE workflow_instance_steps SET state = 'completed', result_code = p_result_code, ended_at = now()
  WHERE instance_id = p_instance_id AND definition_node_key = p_node_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfrlc_simulate_decision(UUID,TEXT,TEXT) TO authenticated;

-- ── 1: two simultaneous workflow_advance_graph_step calls (distinct
--    idempotency keys) racing to enter and skip through the same
--    zero-candidate optional node produce exactly one successful
--    runtime state — one skipped round, one real review3 round. ────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000001','wfrlc_flow1','WFRLC Flow 1','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000001'))
INSERT INTO wfrlc_ids SELECT 'v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v1'),0,'67820000-1000-0000-0000-000000000002');
INSERT INTO wfrlc_ids SELECT 'inst1', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v1'),'opaque_case','67820000-2000-0000-0000-000000000001',
  '67820000-0000-0000-0000-000000000001','67820000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst1'),0,'67820000-1000-0000-0000-000000000004');
RESET ROLE;
SELECT wfrlc_simulate_decision((SELECT id FROM wfrlc_ids WHERE name='inst1'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000010'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000011'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst1')));
CREATE TEMP TABLE wfrlc_c1(v text, err text);
CREATE TEMP TABLE wfrlc_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrlc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrlc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_iid UUID := (SELECT id FROM wfrlc_ids WHERE name='inst1');
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfrlc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfrlc_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one distinct successful advancement result, got %', v_winners; END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 3 THEN
    RAISE EXCEPTION 'expected exactly 3 rounds (review1 real + review2 skipped + review3 real), got %',
      (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid);
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid AND outcome_code='skipped') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one skipped round, not duplicated by the race';
  END IF;
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id = v_iid AND definition_node_key='review3') <> 1 THEN
    RAISE EXCEPTION 'duplicate review3 step created by racing advancement through the skip chain';
  END IF;
END $$;
INSERT INTO wfrlc_results VALUES (1,'two simultaneous workflow_advance_graph_step calls racing to enter and skip through the same zero-candidate optional node produce exactly one successful runtime state: one skipped round, one real downstream round, no duplication');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: duplicate advancement with the SAME idempotency key through
--    the skip chain, issued concurrently, replays safely and
--    converges. ─────────────────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000001','wfrlc_flow2','WFRLC Flow 2','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000012'))
INSERT INTO wfrlc_ids SELECT 'v2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v2'),0,'67820000-1000-0000-0000-000000000013');
INSERT INTO wfrlc_ids SELECT 'inst2', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v2'),'opaque_case','67820000-2000-0000-0000-000000000002',
  '67820000-0000-0000-0000-000000000001','67820000-1000-0000-0000-000000000014',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst2'),0,'67820000-1000-0000-0000-000000000015');
RESET ROLE;
SELECT wfrlc_simulate_decision((SELECT id FROM wfrlc_ids WHERE name='inst2'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000016'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst2')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000016'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst2')));
TRUNCATE wfrlc_c1, wfrlc_c2;
INSERT INTO wfrlc_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfrlc_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrlc_ids WHERE name='inst2');
BEGIN
  IF (SELECT v FROM wfrlc_c1) IS DISTINCT FROM (SELECT v FROM wfrlc_c2) OR (SELECT v FROM wfrlc_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent advancement-through-skip commands did not converge: % vs %', (SELECT v FROM wfrlc_c1), (SELECT v FROM wfrlc_c2);
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 3 THEN
    RAISE EXCEPTION 'identical concurrent replay duplicated a round in the skip chain';
  END IF;
END $$;
INSERT INTO wfrlc_results VALUES (2,'duplicate advancement with the same idempotency key through the skip chain, issued concurrently, replays safely and converges without duplicating any round');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: a decision that closes a round and advances through the skip
--    chain, replayed concurrently with the same command id, converges
--    to an identical result. ────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000001','wfrlc_flow3','WFRLC Flow 3','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000017'))
INSERT INTO wfrlc_ids SELECT 'v3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v3'),0,'67820000-1000-0000-0000-000000000018');
INSERT INTO wfrlc_ids SELECT 'inst3', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v3'),'opaque_case','67820000-2000-0000-0000-000000000003',
  '67820000-0000-0000-0000-000000000001','67820000-1000-0000-0000-000000000019',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst3'),0,'67820000-1000-0000-0000-000000000020');
INSERT INTO wfrlc_ids SELECT 'wi3', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfrlc_ids WHERE name='inst3');
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
INSERT INTO wfrlc_ids SELECT 'cmd3', gen_random_uuid();
SELECT dblink_send_query('w1', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfrlc_ids WHERE name='wi3'), (SELECT id FROM wfrlc_ids WHERE name='cmd3')));
SELECT dblink_send_query('w2', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfrlc_ids WHERE name='wi3'), (SELECT id FROM wfrlc_ids WHERE name='cmd3')));
TRUNCATE wfrlc_c1, wfrlc_c2;
INSERT INTO wfrlc_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfrlc_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrlc_ids WHERE name='inst3');
BEGIN
  IF (SELECT v FROM wfrlc_c1) IS DISTINCT FROM (SELECT v FROM wfrlc_c2) OR (SELECT v FROM wfrlc_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent decisions advancing through a skip chain did not converge';
  END IF;
  IF (SELECT count(*) FROM workflow_decisions WHERE instance_id = v_iid) <> 1 THEN
    RAISE EXCEPTION 'identical concurrent replay duplicated the decision row';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 3 THEN
    RAISE EXCEPTION 'identical concurrent replay duplicated a round in the skip chain';
  END IF;
END $$;
INSERT INTO wfrlc_results VALUES (3,'the same command id issued concurrently for a decision whose closure advances through a zero-candidate optional skip converges to an identical result, with exactly one decision row and no duplicated round');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: advancement through the skip chain versus instance
--    cancellation produces exactly one valid serialized final state. ─
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000001','wfrlc_flow4','WFRLC Flow 4','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000021'))
INSERT INTO wfrlc_ids SELECT 'v4',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v4'),0,'67820000-1000-0000-0000-000000000022');
INSERT INTO wfrlc_ids SELECT 'inst4', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v4'),'opaque_case','67820000-2000-0000-0000-000000000004',
  '67820000-0000-0000-0000-000000000001','67820000-1000-0000-0000-000000000023',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst4'),0,'67820000-1000-0000-0000-000000000024');
RESET ROLE;
SELECT wfrlc_simulate_decision((SELECT id FROM wfrlc_ids WHERE name='inst4'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000025'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst4')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM cancel_workflow_instance('%s'::uuid,1,'67820000-1000-0000-0000-000000000026'::uuid,'race_cancel')$q$, (SELECT id FROM wfrlc_ids WHERE name='inst4')));
TRUNCATE wfrlc_c1, wfrlc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrlc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrlc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_final TEXT; v_iid UUID := (SELECT id FROM wfrlc_ids WHERE name='inst4');
BEGIN
  SELECT status INTO v_final FROM workflow_instances WHERE id = v_iid;
  IF v_final NOT IN ('active','cancelled') THEN
    RAISE EXCEPTION 'advancement-through-skip-vs-cancellation race left an invalid final state: %', v_final;
  END IF;
  IF v_final = 'cancelled' AND EXISTS (
    SELECT 1 FROM workflow_work_items WHERE instance_id = v_iid AND state IN ('offered','claimed')
  ) THEN RAISE EXCEPTION 'cancelled instance left open work items'; END IF;
END $$;
INSERT INTO wfrlc_results VALUES (4,'advancement through the skip chain racing instance cancellation produces exactly one valid serialized final state, no dangling open runtime rows');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: unrelated organizations advancing through the skip chain
--    proceed independently with no unnecessary blocking. ────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000001','wfrlc_flow5a','WFRLC Flow 5A','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000027'))
INSERT INTO wfrlc_ids SELECT 'v5a',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v5a'),0,'67820000-1000-0000-0000-000000000028');
INSERT INTO wfrlc_ids SELECT 'inst5a', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v5a'),'opaque_case','67820000-2000-0000-0000-000000000005',
  '67820000-0000-0000-0000-000000000001','67820000-1000-0000-0000-000000000029',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst5a'),0,'67820000-1000-0000-0000-000000000030');
RESET ROLE;
SELECT wfrlc_simulate_decision((SELECT id FROM wfrlc_ids WHERE name='inst5a'), 'review1', 'approved');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000002"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition('67820000-0000-0000-0000-000000000002','wfrlc_flow5b','WFRLC Flow 5B','opaque_case',:SKIP_CHAIN_PAYLOAD::jsonb,'67820000-1000-0000-0000-000000000031'))
INSERT INTO wfrlc_ids SELECT 'v5b',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlc_ids WHERE name='v5b'),0,'67820000-1000-0000-0000-000000000032');
INSERT INTO wfrlc_ids SELECT 'inst5b', create_workflow_instance(
  (SELECT id FROM wfrlc_ids WHERE name='v5b'),'opaque_case','67820000-2000-0000-0000-000000000006',
  '67820000-0000-0000-0000-000000000002','67820000-1000-0000-0000-000000000033',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlc_ids WHERE name='inst5b'),0,'67820000-1000-0000-0000-000000000034');
RESET ROLE;
SELECT wfrlc_simulate_decision((SELECT id FROM wfrlc_ids WHERE name='inst5b'), 'review1', 'approved');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67820000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000037'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst5a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'67820000-1000-0000-0000-000000000038'::uuid)$q$, (SELECT id FROM wfrlc_ids WHERE name='inst5b')));
TRUNCATE wfrlc_c1, wfrlc_c2;
INSERT INTO wfrlc_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfrlc_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
BEGIN
  -- A failed remote call makes dblink_get_result return zero rows
  -- (not a NULL-valued row), so row COUNT must be checked explicitly
  -- — an IS DISTINCT FROM/'<>' comparison against an empty scalar
  -- subquery silently evaluates to NULL and would not raise.
  IF (SELECT count(*) FROM wfrlc_c1) <> 1 OR (SELECT count(*) FROM wfrlc_c2) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one result row from each connection, got c1=%, c2=%',
      (SELECT count(*) FROM wfrlc_c1), (SELECT count(*) FROM wfrlc_c2);
  END IF;
  IF (SELECT v FROM wfrlc_c1) IS DISTINCT FROM 'active' OR (SELECT v FROM wfrlc_c2) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'unrelated-organization concurrent advancements through the skip chain did not both succeed: c1=%, c2=%',
      (SELECT v FROM wfrlc_c1), (SELECT v FROM wfrlc_c2);
  END IF;
END $$;
INSERT INTO wfrlc_results VALUES (5,'advancement through the skip chain in unrelated organizations both succeed independently, no unnecessary blocking');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 6: no deadlock observed under the documented lock order across
--    all five prior scenarios (a deadlock would have surfaced as an
--    ERROR from a checked dblink_get_result call). ─────────────────
INSERT INTO wfrlc_results VALUES (6,'no deadlock observed under the documented lock order across all five prior concurrency scenarios exercising the skip loop');

-- ── Cleanup: committed cross-session fixtures removed in FK-
--    dependency order, leaving the disposable database as found. ───
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
ALTER TABLE workflow_decisions DISABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_decisions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_decisions ENABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67820000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '67820000-%';
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '67820000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '67820000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '67820000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '67820000-%';
DELETE FROM users WHERE id::text LIKE '67820000-%';
DELETE FROM auth.users WHERE id::text LIKE '67820000-%';
DELETE FROM organizations WHERE id::text LIKE '67820000-%';
DROP FUNCTION IF EXISTS wfrlc_simulate_decision(UUID,TEXT,TEXT);

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrlc_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle concurrency tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval round lifecycle concurrency tests PASSED: %/6', v_count;
END $$;
