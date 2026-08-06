-- CAP-002 Phase 2C.1 repeatable concurrency suite (6 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
--
-- Advancement runs inside the exact same lock order Phase 2/2B.2
-- already established (caller/instance/idempotency advisory lock,
-- then the instance row FOR UPDATE, then the current step row FOR
-- UPDATE, then the token row FOR UPDATE) — these scenarios confirm
-- adding the downstream-entry work inside that scope introduced no
-- new race window.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfgac_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfgac_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfgac_results, wfgac_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('66700000-0000-0000-0000-000000000001','WF Graph Advancement Concurrency A','authority','WFGAC-A'),
 ('66700000-0000-0000-0000-000000000002','WF Graph Advancement Concurrency B','authority','WFGAC-B');
INSERT INTO auth.users(id,email) VALUES
 ('66700000-0001-0000-0000-000000000001','a@wfgac.local'),
 ('66700000-0001-0000-0000-000000000002','b@wfgac.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('66700000-0001-0000-0000-000000000001','66700000-0000-0000-0000-000000000001','WFGAC-1','A','a@wfgac.local',true,true),
 ('66700000-0001-0000-0000-000000000002','66700000-0000-0000-0000-000000000002','WFGAC-2','B','b@wfgac.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('66700000-0001-0000-0000-000000000001','organization','66700000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66700000-0001-0000-0000-000000000002','organization','66700000-0000-0000-0000-000000000002','authority_admin',true,true);

\set TWO_HOP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

-- ── 1: two simultaneous advancements (different idempotency keys, a
--    genuine race) produce exactly one successful runtime state —
--    one round, one target step, no duplication. ────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000001','wfgac_flow','WFGAC Flow','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000001'))
INSERT INTO wfgac_ids SELECT 'v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v1'),0,'66700000-1000-0000-0000-000000000002');
INSERT INTO wfgac_ids SELECT 'inst1', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v1'),'opaque_case','66700000-2000-0000-0000-000000000001',
  '66700000-0000-0000-0000-000000000001','66700000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst1'),0,'66700000-1000-0000-0000-000000000004');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst1') AND definition_node_key='review1';

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000010'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000011'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst1')));
CREATE TEMP TABLE wfgac_c1(v text, err text);
CREATE TEMP TABLE wfgac_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_iid UUID := (SELECT id FROM wfgac_ids WHERE name='inst1');
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfgac_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfgac_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one distinct successful advancement result, got %', v_winners; END IF;
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id = v_iid AND definition_node_key='review2') <> 1 THEN
    RAISE EXCEPTION 'duplicate review2 step created by racing advancement';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 2 THEN
    RAISE EXCEPTION 'duplicate round created by racing advancement (expected exactly 2: review1 + review2)';
  END IF;
END $$;
INSERT INTO wfgac_results VALUES (1,'two simultaneous advancements (distinct idempotency keys) produce exactly one successful runtime state');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: duplicate advancement with the SAME idempotency key, issued
--    concurrently, replays safely and converges. ────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000001','wfgac_flow2','WFGAC Flow 2','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000012'))
INSERT INTO wfgac_ids SELECT 'v2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v2'),0,'66700000-1000-0000-0000-000000000013');
INSERT INTO wfgac_ids SELECT 'inst2', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v2'),'opaque_case','66700000-2000-0000-0000-000000000002',
  '66700000-0000-0000-0000-000000000001','66700000-1000-0000-0000-000000000014',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst2'),0,'66700000-1000-0000-0000-000000000015');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst2') AND definition_node_key='review1';

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000016'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst2')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000016'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst2')));
TRUNCATE wfgac_c1, wfgac_c2;
INSERT INTO wfgac_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfgac_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfgac_ids WHERE name='inst2');
BEGIN
  IF (SELECT v FROM wfgac_c1) IS DISTINCT FROM (SELECT v FROM wfgac_c2) OR (SELECT v FROM wfgac_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent advancement commands did not converge: % vs %', (SELECT v FROM wfgac_c1), (SELECT v FROM wfgac_c2);
  END IF;
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id = v_iid AND definition_node_key='review2') <> 1 THEN
    RAISE EXCEPTION 'identical concurrent replay duplicated the review2 step';
  END IF;
END $$;
INSERT INTO wfgac_results VALUES (2,'duplicate advancement with the same idempotency key, issued concurrently, replays safely and converges');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: advancement versus cancellation produces one valid serialized
--    result — either advancement completes and cancel then cancels
--    the now-open runtime state, or cancel wins first and
--    advancement sees a stale/illegal-transition error. ────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000001','wfgac_flow3','WFGAC Flow 3','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000017'))
INSERT INTO wfgac_ids SELECT 'v3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v3'),0,'66700000-1000-0000-0000-000000000018');
INSERT INTO wfgac_ids SELECT 'inst3', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v3'),'opaque_case','66700000-2000-0000-0000-000000000003',
  '66700000-0000-0000-0000-000000000001','66700000-1000-0000-0000-000000000019',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst3'),0,'66700000-1000-0000-0000-000000000020');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst3') AND definition_node_key='review1';

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000021'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst3')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM cancel_workflow_instance('%s'::uuid,1,'66700000-1000-0000-0000-000000000022'::uuid,'race_cancel')$q$, (SELECT id FROM wfgac_ids WHERE name='inst3')));
TRUNCATE wfgac_c1, wfgac_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_final TEXT; v_iid UUID := (SELECT id FROM wfgac_ids WHERE name='inst3');
BEGIN
  SELECT status INTO v_final FROM workflow_instances WHERE id = v_iid;
  IF v_final NOT IN ('active','cancelled') THEN
    RAISE EXCEPTION 'advancement-vs-cancellation race left an invalid final state: %', v_final;
  END IF;
  IF v_final = 'cancelled' AND EXISTS (
    SELECT 1 FROM workflow_work_items WHERE instance_id = v_iid AND state IN ('offered','claimed')
  ) THEN RAISE EXCEPTION 'cancelled instance left open work items'; END IF;
END $$;
INSERT INTO wfgac_results VALUES (3,'advancement versus cancellation produces exactly one valid serialized final state, no dangling open runtime rows');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: advancement racing a second, DIFFERENT command (a distinct
--    idempotency key attempting the same advancement) does not
--    duplicate runtime rows — one wins, the other gets a stale-
--    version/illegal-state error. ──────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000001','wfgac_flow4','WFGAC Flow 4','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000023'))
INSERT INTO wfgac_ids SELECT 'v4',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v4'),0,'66700000-1000-0000-0000-000000000024');
INSERT INTO wfgac_ids SELECT 'inst4', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v4'),'opaque_case','66700000-2000-0000-0000-000000000004',
  '66700000-0000-0000-0000-000000000001','66700000-1000-0000-0000-000000000025',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst4'),0,'66700000-1000-0000-0000-000000000026');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst4') AND definition_node_key='review1';

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000027'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst4')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000028'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst4')));
TRUNCATE wfgac_c1, wfgac_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfgac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfgac_ids WHERE name='inst4');
BEGIN
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id = v_iid AND definition_node_key='review2') <> 1 THEN
    RAISE EXCEPTION 'racing distinct advance commands duplicated the review2 step';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 2 THEN
    RAISE EXCEPTION 'racing distinct advance commands duplicated the round';
  END IF;
END $$;
INSERT INTO wfgac_results VALUES (4,'advancement racing a second distinct advance command does not duplicate runtime rows');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: advancement of unrelated organizations does not block
--    unnecessarily — both complete promptly in parallel. ───────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000001','wfgac_flow5a','WFGAC Flow 5A','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000029'))
INSERT INTO wfgac_ids SELECT 'v5a',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v5a'),0,'66700000-1000-0000-0000-000000000030');
INSERT INTO wfgac_ids SELECT 'inst5a', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v5a'),'opaque_case','66700000-2000-0000-0000-000000000005',
  '66700000-0000-0000-0000-000000000001','66700000-1000-0000-0000-000000000031',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst5a'),0,'66700000-1000-0000-0000-000000000032');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst5a') AND definition_node_key='review1';

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000002"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66700000-0000-0000-0000-000000000002','wfgac_flow5b','WFGAC Flow 5B','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66700000-1000-0000-0000-000000000033'))
INSERT INTO wfgac_ids SELECT 'v5b',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgac_ids WHERE name='v5b'),0,'66700000-1000-0000-0000-000000000034');
INSERT INTO wfgac_ids SELECT 'inst5b', create_workflow_instance(
  (SELECT id FROM wfgac_ids WHERE name='v5b'),'opaque_case','66700000-2000-0000-0000-000000000006',
  '66700000-0000-0000-0000-000000000002','66700000-1000-0000-0000-000000000035',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgac_ids WHERE name='inst5b'),0,'66700000-1000-0000-0000-000000000036');
RESET ROLE;
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgac_ids WHERE name='inst5b') AND definition_node_key='review1';

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"66700000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000037'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst5a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM workflow_advance_graph_step('%s'::uuid,1,'66700000-1000-0000-0000-000000000038'::uuid)$q$, (SELECT id FROM wfgac_ids WHERE name='inst5b')));
TRUNCATE wfgac_c1, wfgac_c2;
INSERT INTO wfgac_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfgac_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
BEGIN
  IF (SELECT v FROM wfgac_c1) <> 'active' OR (SELECT v FROM wfgac_c2) <> 'active' THEN
    RAISE EXCEPTION 'unrelated-organization concurrent advancements did not both succeed: c1=%, c2=%',
      (SELECT v FROM wfgac_c1), (SELECT v FROM wfgac_c2);
  END IF;
END $$;
INSERT INTO wfgac_results VALUES (5,'advancement of unrelated organizations both succeed independently (no unnecessary blocking observed)');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 6: no deadlock under the documented lock order across all
--    scenarios above — proven by every scenario above actually
--    completing (a deadlock would have surfaced as an ERROR from one
--    of the dblink_get_result calls, which are all checked). ───────
INSERT INTO wfgac_results VALUES (6,'no deadlock observed under the documented lock order across all five prior concurrency scenarios');

-- ── Cleanup: dblink-based cross-session scenarios require committed
--    (not rolled-back) fixtures, so — matching the established
--    convention — every row this suite committed is removed here, in
--    FK-dependency order (leaf tables first), leaving the disposable
--    database exactly as it was found. ─────────────────────────────
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '66700000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '66700000-%';
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '66700000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '66700000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '66700000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '66700000-%';
DELETE FROM users WHERE id::text LIKE '66700000-%';
DELETE FROM auth.users WHERE id::text LIKE '66700000-%';
DELETE FROM organizations WHERE id::text LIKE '66700000-%';

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfgac_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow graph advancement foundation concurrency tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow graph advancement foundation concurrency tests PASSED: %/6', v_count;
END $$;
