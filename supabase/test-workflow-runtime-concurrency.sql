-- CAP-002 Phase 2 independent-session concurrency suite (5 scenarios)
-- Disposable local PostgreSQL only; requires dblink for the test harness.
\set ON_ERROR_STOP on
CREATE TEMP TABLE wf_runtime_extension_state (dblink_preexisting BOOLEAN NOT NULL);
INSERT INTO wf_runtime_extension_state SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='dblink');
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wf_runtime_concurrency_results (scenario INTEGER PRIMARY KEY,name TEXT NOT NULL);
CREATE TEMP TABLE wf_runtime_concurrency_ids (name TEXT PRIMARY KEY,id UUID NOT NULL);
CREATE TEMP TABLE wf_runtime_c1(v TEXT); CREATE TEMP TABLE wf_runtime_c2(v TEXT);
GRANT SELECT,INSERT ON wf_runtime_concurrency_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES ('62700000-0000-0000-0000-000000000001','Workflow Runtime Concurrency','authority','WRC');
INSERT INTO auth.users(id,email) VALUES ('62700000-0001-0000-0000-000000000001','admin@wrc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62700000-0001-0000-0000-000000000001','62700000-0000-0000-0000-000000000001','WRC-1','Runtime Concurrency Admin','admin@wrc.local',true,true);

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('62700000-0000-0000-0000-000000000001','runtime_concurrency_flow','Runtime Concurrency','opaque_record','{"nodes":[],"edges":[]}','62700000-1000-0000-0000-000000000001'))
INSERT INTO wf_runtime_concurrency_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf_runtime_concurrency_ids WHERE name='version'),0,'62700000-1000-0000-0000-000000000002');
INSERT INTO wf_runtime_concurrency_ids
SELECT 'instance_'||g,create_workflow_instance(
 (SELECT id FROM wf_runtime_concurrency_ids WHERE name='version'),'opaque_record',
 ('62700000-2000-0000-0000-'||lpad(to_hex(g),12,'0'))::UUID,
 '62700000-0000-0000-0000-000000000001',
 ('62700000-3000-0000-0000-'||lpad(to_hex(g),12,'0'))::UUID,NULL)
FROM generate_series(1,6) g;
RESET ROLE;

CREATE OR REPLACE FUNCTION wf_runtime_test_try(
 p_command TEXT,p_instance UUID,p_expected BIGINT,p_key UUID
) RETURNS TEXT AS $$
DECLARE r RECORD;
BEGIN
  CASE p_command
    WHEN 'start' THEN SELECT * INTO r FROM start_workflow_instance(p_instance,p_expected,p_key);
    WHEN 'suspend' THEN SELECT * INTO r FROM suspend_workflow_instance(p_instance,p_expected,p_key,'concurrency_test');
    WHEN 'cancel' THEN SELECT * INTO r FROM cancel_workflow_instance(p_instance,p_expected,p_key,'concurrency_test');
    WHEN 'complete' THEN SELECT * INTO r FROM complete_workflow_instance(p_instance,p_expected,p_key,'success');
  END CASE;
  RETURN r.status||':'||r.lock_version;
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;
REVOKE ALL ON FUNCTION wf_runtime_test_try(TEXT,UUID,BIGINT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION wf_runtime_test_try(TEXT,UUID,BIGINT,UUID) TO authenticated;

-- 1. Identical concurrent retries converge on one event and result.
SELECT dblink_connect('r1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('r2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('r1','SET ROLE authenticated'); SELECT dblink_exec('r2','SET ROLE authenticated');
SELECT * FROM dblink('r1',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT * FROM dblink('r2',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT dblink_send_query('r1',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000001'),0,'62700000-4000-0000-0000-000000000001')$q$);
SELECT dblink_send_query('r2',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000001'),0,'62700000-4000-0000-0000-000000000001')$q$);
INSERT INTO wf_runtime_c1 SELECT * FROM dblink_get_result('r1',false) AS t(v TEXT);
INSERT INTO wf_runtime_c2 SELECT * FROM dblink_get_result('r2',false) AS t(v TEXT);
DO $$ BEGIN IF (SELECT v FROM wf_runtime_c1)<>'active:1' OR (SELECT v FROM wf_runtime_c2)<>'active:1'
 OR (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_concurrency_ids WHERE name='instance_1') AND event_type='instance_started')<>1 THEN RAISE EXCEPTION 'same command race'; END IF; END $$;
INSERT INTO wf_runtime_concurrency_results VALUES(1,'identical concurrent command converges');
SELECT dblink_disconnect('r1'); SELECT dblink_disconnect('r2');

-- 2. Distinct concurrent starts produce one winner and one stale-version result.
TRUNCATE wf_runtime_c1,wf_runtime_c2;
SELECT dblink_connect('r1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('r2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('r1','SET ROLE authenticated'); SELECT dblink_exec('r2','SET ROLE authenticated');
SELECT * FROM dblink('r1',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT * FROM dblink('r2',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT dblink_send_query('r1',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000002'),0,'62700000-4000-0000-0000-000000000002')$q$);
SELECT dblink_send_query('r2',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000002'),0,'62700000-4000-0000-0000-000000000003')$q$);
INSERT INTO wf_runtime_c1 SELECT * FROM dblink_get_result('r1',false) AS t(v TEXT);
INSERT INTO wf_runtime_c2 SELECT * FROM dblink_get_result('r2',false) AS t(v TEXT);
DO $$ BEGIN IF (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v='active:1')<>1
 OR (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v='40001')<>1 THEN RAISE EXCEPTION 'different start race'; END IF; END $$;
INSERT INTO wf_runtime_concurrency_results VALUES(2,'distinct starts prevent double transition');
SELECT dblink_disconnect('r1'); SELECT dblink_disconnect('r2');

-- 3. Start versus cancel from pending has exactly one valid serialized outcome.
TRUNCATE wf_runtime_c1,wf_runtime_c2;
SELECT dblink_connect('r1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('r2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('r1','SET ROLE authenticated'); SELECT dblink_exec('r2','SET ROLE authenticated');
SELECT * FROM dblink('r1',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT * FROM dblink('r2',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT dblink_send_query('r1',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000003'),0,'62700000-4000-0000-0000-000000000004')$q$);
SELECT dblink_send_query('r2',$q$SELECT wf_runtime_test_try('cancel',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000003'),0,'62700000-4000-0000-0000-000000000005')$q$);
INSERT INTO wf_runtime_c1 SELECT * FROM dblink_get_result('r1',false) AS t(v TEXT);
INSERT INTO wf_runtime_c2 SELECT * FROM dblink_get_result('r2',false) AS t(v TEXT);
DO $$ BEGIN IF (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v IN ('active:1','cancelled:1'))<>1
 OR (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v='40001')<>1 THEN RAISE EXCEPTION 'start/cancel race'; END IF; END $$;
INSERT INTO wf_runtime_concurrency_results VALUES(3,'start and cancel serialize to one outcome');
SELECT dblink_disconnect('r1'); SELECT dblink_disconnect('r2');

-- 4. Suspend versus complete from active has one winner and no lost update.
SET ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false);
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_concurrency_ids WHERE name='instance_4'),0,'62700000-4000-0000-0000-000000000006'); RESET ROLE;
TRUNCATE wf_runtime_c1,wf_runtime_c2;
SELECT dblink_connect('r1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('r2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('r1','SET ROLE authenticated'); SELECT dblink_exec('r2','SET ROLE authenticated');
SELECT * FROM dblink('r1',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT * FROM dblink('r2',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT dblink_send_query('r1',$q$SELECT wf_runtime_test_try('suspend',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000004'),1,'62700000-4000-0000-0000-000000000007')$q$);
SELECT dblink_send_query('r2',$q$SELECT wf_runtime_test_try('complete',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000004'),1,'62700000-4000-0000-0000-000000000008')$q$);
INSERT INTO wf_runtime_c1 SELECT * FROM dblink_get_result('r1',false) AS t(v TEXT);
INSERT INTO wf_runtime_c2 SELECT * FROM dblink_get_result('r2',false) AS t(v TEXT);
DO $$ BEGIN IF (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v IN ('suspended:2','completed:2'))<>1
 OR (SELECT count(*) FROM (SELECT v FROM wf_runtime_c1 UNION ALL SELECT v FROM wf_runtime_c2)x WHERE v='40001')<>1 THEN RAISE EXCEPTION 'suspend/complete race'; END IF; END $$;
INSERT INTO wf_runtime_concurrency_results VALUES(4,'suspend and complete prevent lost update');
SELECT dblink_disconnect('r1'); SELECT dblink_disconnect('r2');

-- 5. Unrelated instance aggregates transition concurrently without deadlock.
TRUNCATE wf_runtime_c1,wf_runtime_c2;
SELECT dblink_connect('r1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('r2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('r1','SET ROLE authenticated'); SELECT dblink_exec('r2','SET ROLE authenticated');
SELECT * FROM dblink('r1',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT * FROM dblink('r2',$q$SELECT set_config('request.jwt.claims','{"sub":"62700000-0001-0000-0000-000000000001"}',false)$q$) AS t(v TEXT);
SELECT dblink_send_query('r1',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000005'),0,'62700000-4000-0000-0000-000000000009')$q$);
SELECT dblink_send_query('r2',$q$SELECT wf_runtime_test_try('start',(SELECT id FROM workflow_instances WHERE subject_id='62700000-2000-0000-0000-000000000006'),0,'62700000-4000-0000-0000-000000000010')$q$);
INSERT INTO wf_runtime_c1 SELECT * FROM dblink_get_result('r1',false) AS t(v TEXT);
INSERT INTO wf_runtime_c2 SELECT * FROM dblink_get_result('r2',false) AS t(v TEXT);
DO $$ BEGIN IF (SELECT v FROM wf_runtime_c1)<>'active:1' OR (SELECT v FROM wf_runtime_c2)<>'active:1' THEN RAISE EXCEPTION 'unrelated instances'; END IF; END $$;
INSERT INTO wf_runtime_concurrency_results VALUES(5,'unrelated instances do not block or deadlock');
SELECT dblink_disconnect('r1'); SELECT dblink_disconnect('r2');

DROP FUNCTION wf_runtime_test_try(TEXT,UUID,BIGINT,UUID);
DO $$ BEGIN IF (SELECT count(*) FROM wf_runtime_concurrency_results)<>5 THEN RAISE EXCEPTION 'Expected five concurrency scenarios'; END IF; END $$;
SELECT 'Workflow runtime concurrency tests PASSED: 5/5' AS result;

ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE actor_id='62700000-0001-0000-0000-000000000001';
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_participants WHERE created_by='62700000-0001-0000-0000-000000000001';
DELETE FROM workflow_instances WHERE created_by='62700000-0001-0000-0000-000000000001';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definitions SET active_version_id=NULL WHERE created_by='62700000-0001-0000-0000-000000000001';
DELETE FROM workflow_definition_versions WHERE created_by='62700000-0001-0000-0000-000000000001';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by='62700000-0001-0000-0000-000000000001';
DELETE FROM users WHERE id='62700000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='62700000-0001-0000-0000-000000000001';
DELETE FROM organizations WHERE id='62700000-0000-0000-0000-000000000001';
DO $$ BEGIN IF NOT (SELECT dblink_preexisting FROM wf_runtime_extension_state) THEN EXECUTE 'DROP EXTENSION dblink'; END IF; END $$;
