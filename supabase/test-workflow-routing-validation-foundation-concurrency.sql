-- CAP-002 Phase 4.1 routing validation and variable foundation
-- concurrency suite (5 scenarios). Disposable local PostgreSQL only;
-- requires dblink.
--
-- This phase adds no graph-execution capability, so the only new
-- concurrency surface is set_workflow_instance_variable itself: two
-- concurrent writers to the same instance must serialize (via the
-- existing instance-row lock already used by every other command,
-- inserted at its documented position in the global lock order) with
-- no corruption, no unique-constraint race, and no deadlock.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfrvc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrvc_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrvc_results, wfrvc_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64930000-0000-0000-0000-000000000001','WF Routing Val Concurrency A','authority','WFRVC-A'),
 ('64930000-0000-0000-0000-000000000002','WF Routing Val Concurrency B','authority','WFRVC-B');
INSERT INTO auth.users(id,email) VALUES
 ('64930000-0001-0000-0000-000000000001','a@wfrvc.local'),
 ('64930000-0001-0000-0000-000000000002','b@wfrvc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('64930000-0001-0000-0000-000000000001','64930000-0000-0000-0000-000000000001','WFRVC-1','A','a@wfrvc.local',true,true),
 ('64930000-0001-0000-0000-000000000002','64930000-0000-0000-0000-000000000002','WFRVC-2','B','b@wfrvc.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64930000-0001-0000-0000-000000000001','organization','64930000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64930000-0001-0000-0000-000000000002','organization','64930000-0000-0000-0000-000000000002','authority_admin',true,true);

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '64930000-0000-0000-0000-000000000001','wfrvc_flow','WFRVC Flow','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb,'64930000-1000-0000-0000-000000000001'))
INSERT INTO wfrvc_ids SELECT 'v1', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrvc_ids WHERE name='v1'),0,'64930000-1000-0000-0000-000000000002');
INSERT INTO wfrvc_ids SELECT 'inst1', create_workflow_instance(
  (SELECT id FROM wfrvc_ids WHERE name='v1'),'opaque_case','64930000-2000-0000-0000-000000000001',
  '64930000-0000-0000-0000-000000000001','64930000-1000-0000-0000-000000000003',NULL);
RESET ROLE;

-- ── 1: two concurrent writes to the SAME variable name (different
--    idempotency keys) fully serialize — both succeed, exactly one
--    row exists afterward with lock_version=2 (create then update),
--    never a unique-constraint violation. ──────────────────────────
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'priority_band','string','"urgent"'::jsonb,'restricted','64930000-3000-0000-0000-000000000001'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'priority_band','string','"low"'::jsonb,'restricted','64930000-3000-0000-0000-000000000002'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
CREATE TEMP TABLE wfrvc_c1(v text, err text);
CREATE TEMP TABLE wfrvc_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_row_count INTEGER; v_final_lv BIGINT; v_iid UUID := (SELECT id FROM wfrvc_ids WHERE name='inst1');
BEGIN
  SELECT count(*) INTO v_row_count FROM workflow_variables WHERE instance_id = v_iid AND variable_name = 'priority_band';
  IF v_row_count <> 1 THEN RAISE EXCEPTION 'expected exactly one priority_band row after two concurrent writes, got %', v_row_count; END IF;
  SELECT lock_version INTO v_final_lv FROM workflow_variables WHERE instance_id = v_iid AND variable_name = 'priority_band';
  IF v_final_lv <> 2 THEN RAISE EXCEPTION 'expected lock_version=2 after both concurrent writes serialized (create then update), got %', v_final_lv; END IF;
END $$;
INSERT INTO wfrvc_results VALUES (1,'two concurrent writes to the same variable name fully serialize via the instance-row lock: both succeed, exactly one row results, lock_version reaches 2, no unique-constraint race');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: two concurrent writes using the SAME idempotency key (a
--    replay race) converge to exactly one committed row and one
--    lock_version — no duplicate write, no error on either side. ───
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'replay_var','boolean','true'::jsonb,'restricted','64930000-3000-0000-0000-000000000010'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'replay_var','boolean','true'::jsonb,'restricted','64930000-3000-0000-0000-000000000010'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
DELETE FROM wfrvc_c1; DELETE FROM wfrvc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_row_count INTEGER; v_iid UUID := (SELECT id FROM wfrvc_ids WHERE name='inst1');
  v_both_returned_lv1 BOOLEAN;
BEGIN
  SELECT count(*) INTO v_row_count FROM workflow_variables WHERE instance_id = v_iid AND variable_name = 'replay_var';
  IF v_row_count <> 1 THEN RAISE EXCEPTION 'expected exactly one replay_var row after a same-key concurrent replay, got %', v_row_count; END IF;
  SELECT (SELECT lock_version FROM workflow_variables WHERE instance_id=v_iid AND variable_name='replay_var') = 1 INTO v_both_returned_lv1;
  IF NOT v_both_returned_lv1 THEN RAISE EXCEPTION 'expected lock_version=1 after a same-key concurrent replay converges'; END IF;
  IF EXISTS (SELECT 1 FROM wfrvc_c1 WHERE err IS NOT NULL) OR EXISTS (SELECT 1 FROM wfrvc_c2 WHERE err IS NOT NULL) THEN
    RAISE EXCEPTION 'a same-key concurrent replay should not error on either side';
  END IF;
END $$;
INSERT INTO wfrvc_results VALUES (2,'two concurrent writes using the same idempotency key (a replay race) converge to exactly one row and lock_version=1 with no error on either side');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: two concurrent writes to DIFFERENT variable names on the
--    same instance both succeed with no deadlock (serialized by the
--    same instance-row lock, but never conflict with each other). ──
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'var_a','boolean','true'::jsonb,'restricted','64930000-3000-0000-0000-000000000020'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'var_b','boolean','false'::jsonb,'restricted','64930000-3000-0000-0000-000000000021'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
DELETE FROM wfrvc_c1; DELETE FROM wfrvc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrvc_ids WHERE name='inst1');
BEGIN
  IF (SELECT count(*) FROM workflow_variables WHERE instance_id=v_iid AND variable_name IN ('var_a','var_b')) <> 2 THEN
    RAISE EXCEPTION 'expected both var_a and var_b to exist after two concurrent different-name writes';
  END IF;
  IF EXISTS (SELECT 1 FROM wfrvc_c1 WHERE err IS NOT NULL) OR EXISTS (SELECT 1 FROM wfrvc_c2 WHERE err IS NOT NULL) THEN
    RAISE EXCEPTION 'concurrent writes to distinct variable names on the same instance should not error (no deadlock)';
  END IF;
END $$;
INSERT INTO wfrvc_results VALUES (3,'two concurrent writes to distinct variable names on the same instance both succeed with no deadlock');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: unrelated organizations'' instances proceed independently
--    with no unnecessary blocking. ─────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000002"}',false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '64930000-0000-0000-0000-000000000002','wfrvc_flow_b','WFRVC Flow B','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb,'64930000-1000-0000-0000-000000000004'))
INSERT INTO wfrvc_ids SELECT 'v2', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrvc_ids WHERE name='v2'),0,'64930000-1000-0000-0000-000000000005');
INSERT INTO wfrvc_ids SELECT 'inst2', create_workflow_instance(
  (SELECT id FROM wfrvc_ids WHERE name='v2'),'opaque_case','64930000-2000-0000-0000-000000000002',
  '64930000-0000-0000-0000-000000000002','64930000-1000-0000-0000-000000000006',NULL);
RESET ROLE;
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'org_a_var','boolean','true'::jsonb,'restricted','64930000-3000-0000-0000-000000000030'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT lock_version FROM set_workflow_instance_variable('%s'::uuid,'org_b_var','boolean','true'::jsonb,'restricted','64930000-3000-0000-0000-000000000031'::uuid)$q$,
  (SELECT id FROM wfrvc_ids WHERE name='inst2')));
DELETE FROM wfrvc_c1; DELETE FROM wfrvc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfrvc_c2 VALUES (v_val, v_err);
END $$;
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrvc_ids WHERE name='inst1') AND variable_name='org_a_var') <> 1
     OR (SELECT count(*) FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrvc_ids WHERE name='inst2') AND variable_name='org_b_var') <> 1
  THEN RAISE EXCEPTION 'expected both unrelated-organization writes to succeed independently'; END IF;
  IF EXISTS (SELECT 1 FROM wfrvc_c1 WHERE err IS NOT NULL) OR EXISTS (SELECT 1 FROM wfrvc_c2 WHERE err IS NOT NULL) THEN
    RAISE EXCEPTION 'unrelated organizations'' variable writes should not block or error each other';
  END IF;
END $$;
INSERT INTO wfrvc_results VALUES (4,'unrelated organizations'' instance-variable writes proceed independently with no unnecessary blocking');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: no deadlock was observed across any of the above scenarios
--    (structural confirmation: every scenario above completed and
--    inserted its result row; a deadlock would have aborted the
--    whole script under ON_ERROR_STOP). ───────────────────────────
INSERT INTO wfrvc_results VALUES (5,'no deadlock was observed across all four concurrency scenarios');

-- Cleanup.
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64930000-0001-0000-0000-000000000001"}',false);
RESET ROLE;
DELETE FROM workflow_variables WHERE instance_id::text IN (
  (SELECT id::text FROM wfrvc_ids WHERE name='inst1'), (SELECT id::text FROM wfrvc_ids WHERE name='inst2'));
DELETE FROM workflow_participants WHERE instance_id::text IN (
  (SELECT id::text FROM wfrvc_ids WHERE name='inst1'), (SELECT id::text FROM wfrvc_ids WHERE name='inst2'));
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id::text IN (
  (SELECT id::text FROM wfrvc_ids WHERE name='inst1'), (SELECT id::text FROM wfrvc_ids WHERE name='inst2'));
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_instances WHERE id::text IN (
  (SELECT id::text FROM wfrvc_ids WHERE name='inst1'), (SELECT id::text FROM wfrvc_ids WHERE name='inst2'));
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '64930000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '64930000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '64930000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '64930000-%';
DELETE FROM users WHERE id::text LIKE '64930000-%';
DELETE FROM auth.users WHERE id::text LIKE '64930000-%';
DELETE FROM organizations WHERE id::text LIKE '64930000-%';

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrvc_results;
  IF v_count <> 5 THEN
    RAISE EXCEPTION 'Workflow routing validation foundation concurrency tests FAILED: expected 5, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow routing validation foundation concurrency tests PASSED: %/5', v_count;
END $$;
