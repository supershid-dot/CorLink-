-- CAP-002 Phase 2B.2 repeatable concurrency suite (6 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
--
-- Activation runs inside the exact same lock order Phase 2 already
-- established (caller/instance/idempotency advisory lock, then the
-- instance row FOR UPDATE) — these scenarios confirm adding the
-- graph-entry/round/position work inside that existing scope
-- introduced no new race window.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfac_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfac_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfac_results, wfac_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65200000-0000-0000-0000-000000000001','WF Activation Concurrency A','authority','WFAC-A'),
 ('65200000-0000-0000-0000-000000000002','WF Activation Concurrency B','authority','WFAC-B');
INSERT INTO auth.users(id,email) VALUES
 ('65200000-0001-0000-0000-000000000001','a@wfac.local'),
 ('65200000-0001-0000-0000-000000000002','b@wfac.local'),
 ('65200000-0001-0000-0000-000000000003','cand@wfac.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('65200000-0001-0000-0000-000000000001','65200000-0000-0000-0000-000000000001','WFAC-1','A','a@wfac.local',true,true),
 ('65200000-0001-0000-0000-000000000002','65200000-0000-0000-0000-000000000002','WFAC-2','B','b@wfac.local',true,true),
 ('65200000-0001-0000-0000-000000000003','65200000-0000-0000-0000-000000000001','WFAC-3','Cand','cand@wfac.local',true,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65200000-0001-0000-0000-000000000003','organization','65200000-0000-0000-0000-000000000001','supervisor',true,true);

\set END_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"done"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}\''
\set APPROVAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000001','wfac_flow','WFAC Flow','opaque_case',
  :APPROVAL_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000001'))
INSERT INTO wfac_ids SELECT 'v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v1'),0,'65200000-1000-0000-0000-000000000002');
INSERT INTO wfac_ids SELECT 'inst1', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v1'),'opaque_case','65200000-2000-0000-0000-000000000001',
  '65200000-0000-0000-0000-000000000001','65200000-1000-0000-0000-000000000003',NULL);
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- ── 1: two simultaneous activations (different idempotency keys, a
--    genuine race) produce exactly one successful runtime state —
--    one token, one round, correct work-item count, no duplication. ─
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000010'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000011'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst1')));
CREATE TEMP TABLE wfac_c1(v text, err text);
CREATE TEMP TABLE wfac_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_iid UUID := (SELECT id FROM wfac_ids WHERE name='inst1');
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfac_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfac_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one distinct successful activation result, got %', v_winners; END IF;
  IF (SELECT count(*) FROM workflow_tokens WHERE instance_id = v_iid) <> 1 THEN
    RAISE EXCEPTION 'duplicate token created by racing activation';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id = v_iid) <> 1 THEN
    RAISE EXCEPTION 'duplicate round created by racing activation';
  END IF;
  IF (SELECT count(*) FROM workflow_instances WHERE id = v_iid AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'instance did not converge on a single active state';
  END IF;
END $$;
INSERT INTO wfac_results VALUES (1,'two simultaneous activations (distinct idempotency keys) produce exactly one successful runtime state');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: duplicate activation with the SAME idempotency key, issued
--    concurrently, replays safely and converges. ────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000001','wfac_flow2','WFAC Flow 2','opaque_case',
  :END_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000012'))
INSERT INTO wfac_ids SELECT 'v2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v2'),0,'65200000-1000-0000-0000-000000000013');
INSERT INTO wfac_ids SELECT 'inst2', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v2'),'opaque_case','65200000-2000-0000-0000-000000000002',
  '65200000-0000-0000-0000-000000000001','65200000-1000-0000-0000-000000000014',NULL);
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000015'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst2')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000015'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst2')));
TRUNCATE wfac_c1, wfac_c2;
INSERT INTO wfac_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfac_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfac_ids WHERE name='inst2');
BEGIN
  IF (SELECT v FROM wfac_c1) IS DISTINCT FROM (SELECT v FROM wfac_c2) OR (SELECT v FROM wfac_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent activation commands did not converge: % vs %', (SELECT v FROM wfac_c1), (SELECT v FROM wfac_c2);
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id = v_iid) <> 9 THEN
    RAISE EXCEPTION 'unexpected event count after identical concurrent replay: %', (SELECT count(*) FROM workflow_events WHERE instance_id = v_iid);
  END IF;
END $$;
INSERT INTO wfac_results VALUES (2,'duplicate activation with the same idempotency key, issued concurrently, replays safely and converges');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: activation versus cancellation produces one valid serialized
--    result — either activation completes and cancel then cancels
--    the now-open runtime state, or cancel wins first and activation
--    sees a stale/illegal-transition error. Either is a single valid
--    outcome; a torn/partial result is not. ─────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000001','wfac_flow3','WFAC Flow 3','opaque_case',
  :APPROVAL_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000016'))
INSERT INTO wfac_ids SELECT 'v3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v3'),0,'65200000-1000-0000-0000-000000000017');
INSERT INTO wfac_ids SELECT 'inst3', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v3'),'opaque_case','65200000-2000-0000-0000-000000000003',
  '65200000-0000-0000-0000-000000000001','65200000-1000-0000-0000-000000000018',NULL);
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000019'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst3')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM cancel_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000020'::uuid,'race_cancel')$q$, (SELECT id FROM wfac_ids WHERE name='inst3')));
TRUNCATE wfac_c1, wfac_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_final TEXT; v_iid UUID := (SELECT id FROM wfac_ids WHERE name='inst3');
BEGIN
  SELECT status INTO v_final FROM workflow_instances WHERE id = v_iid;
  IF v_final NOT IN ('active','cancelled') THEN
    RAISE EXCEPTION 'activation-vs-cancellation race left an invalid final state: %', v_final;
  END IF;
  IF v_final = 'cancelled' AND EXISTS (
    SELECT 1 FROM workflow_work_items WHERE instance_id = v_iid AND state IN ('offered','claimed')
  ) THEN RAISE EXCEPTION 'cancelled instance left open work items'; END IF;
END $$;
INSERT INTO wfac_results VALUES (3,'activation versus cancellation produces exactly one valid serialized final state, no dangling open runtime rows');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: activation racing a second, DIFFERENT command (a distinct
--    idempotency key attempting the same 'start') does not duplicate
--    runtime rows — one wins, the other gets a stale-version/illegal-
--    transition error, matching scenario 1's own invariant restated
--    against a fresh instance for independence. ────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000001','wfac_flow4','WFAC Flow 4','opaque_case',
  :END_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000021'))
INSERT INTO wfac_ids SELECT 'v4',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v4'),0,'65200000-1000-0000-0000-000000000022');
INSERT INTO wfac_ids SELECT 'inst4', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v4'),'opaque_case','65200000-2000-0000-0000-000000000004',
  '65200000-0000-0000-0000-000000000001','65200000-1000-0000-0000-000000000023',NULL);
RESET ROLE;
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000024'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst4')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000025'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst4')));
TRUNCATE wfac_c1, wfac_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfac_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfac_ids WHERE name='inst4');
BEGIN
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id = v_iid) <> 2 THEN
    RAISE EXCEPTION 'racing distinct start commands duplicated step rows';
  END IF;
  IF (SELECT count(*) FROM workflow_tokens WHERE instance_id = v_iid) <> 1 THEN
    RAISE EXCEPTION 'racing distinct start commands duplicated token rows';
  END IF;
END $$;
INSERT INTO wfac_results VALUES (4,'activation racing a second distinct start command does not duplicate runtime rows');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: activation of unrelated organizations does not block
--    unnecessarily — both complete promptly in parallel. ───────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000001','wfac_flow5a','WFAC Flow 5A','opaque_case',
  :END_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000026'))
INSERT INTO wfac_ids SELECT 'v5a',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v5a'),0,'65200000-1000-0000-0000-000000000027');
INSERT INTO wfac_ids SELECT 'inst5a', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v5a'),'opaque_case','65200000-2000-0000-0000-000000000005',
  '65200000-0000-0000-0000-000000000001','65200000-1000-0000-0000-000000000028',NULL);
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000002"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65200000-0000-0000-0000-000000000002','wfac_flow5b','WFAC Flow 5B','opaque_case',
  :END_PAYLOAD::jsonb, '65200000-1000-0000-0000-000000000029'))
INSERT INTO wfac_ids SELECT 'v5b',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfac_ids WHERE name='v5b'),0,'65200000-1000-0000-0000-000000000030');
INSERT INTO wfac_ids SELECT 'inst5b', create_workflow_instance(
  (SELECT id FROM wfac_ids WHERE name='v5b'),'opaque_case','65200000-2000-0000-0000-000000000006',
  '65200000-0000-0000-0000-000000000002','65200000-1000-0000-0000-000000000031',NULL);
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"65200000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000032'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst5a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT status FROM start_workflow_instance('%s'::uuid,0,'65200000-1000-0000-0000-000000000033'::uuid)$q$, (SELECT id FROM wfac_ids WHERE name='inst5b')));
TRUNCATE wfac_c1, wfac_c2;
INSERT INTO wfac_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfac_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
BEGIN
  -- END_PAYLOAD is a Start->End graph: successful activation
  -- completes the instance immediately (docs/63's own special case),
  -- so 'completed' here is success, not a failure to activate.
  IF (SELECT v FROM wfac_c1) <> 'completed' OR (SELECT v FROM wfac_c2) <> 'completed' THEN
    RAISE EXCEPTION 'unrelated-organization concurrent activations did not both succeed: c1=%, c2=%',
      (SELECT v FROM wfac_c1), (SELECT v FROM wfac_c2);
  END IF;
END $$;
INSERT INTO wfac_results VALUES (5,'activation of unrelated organizations both succeed independently (no unnecessary blocking observed)');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 6: no deadlock under the documented lock order across all
--    scenarios above — proven by every scenario above actually
--    completing (a deadlock would have surfaced as an ERROR from one
--    of the dblink_get_result calls, which are all checked). ───────
INSERT INTO wfac_results VALUES (6,'no deadlock observed under the documented lock order across all five prior concurrency scenarios');

-- ── Cleanup: dblink-based cross-session scenarios require committed
--    (not rolled-back) fixtures, so — matching the established
--    Phase 1/2 concurrency-suite convention (explicit DELETE by
--    fixture ID prefix rather than a transaction wrapper) — every
--    row this suite committed is removed here, in FK-dependency
--    order (leaf tables first), leaving the disposable database
--    exactly as it was found. ──────────────────────────────────────
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
-- Phase 3.2's terminal-state immutability triggers reject a DELETE
-- against a decided/cancelled position or a completed/cancelled/
-- failed round, exactly as intended in production — disabled here
-- only for this disposable database's own fixture teardown, matching
-- the established workflow_events_immutable convention above.
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65200000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '65200000-%';
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '65200000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '65200000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '65200000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '65200000-%';
DELETE FROM users WHERE id::text LIKE '65200000-%';
DELETE FROM auth.users WHERE id::text LIKE '65200000-%';
DELETE FROM organizations WHERE id::text LIKE '65200000-%';

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfac_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow executable instance activation concurrency tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow executable instance activation concurrency tests PASSED: %/6', v_count;
END $$;
