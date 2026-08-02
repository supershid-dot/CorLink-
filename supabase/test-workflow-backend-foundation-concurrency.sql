-- CAP-002 Phase 1 repeatable concurrency suite (5 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
\set ON_ERROR_STOP on
CREATE TEMP TABLE wf_extension_state (dblink_preexisting BOOLEAN NOT NULL);
INSERT INTO wf_extension_state SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='dblink');
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wf_concurrency_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('62200000-0000-0000-0000-000000000001','Workflow Concurrency A','authority','WFC-A'),
 ('62200000-0000-0000-0000-000000000002','Workflow Concurrency B','authority','WFC-B');
INSERT INTO auth.users(id,email) VALUES
 ('62200000-0001-0000-0000-000000000001','a@wfc.local'),
 ('62200000-0001-0000-0000-000000000002','b@wfc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62200000-0001-0000-0000-000000000001','62200000-0000-0000-0000-000000000001','WFC-1','Concurrency A','a@wfc.local',true,true),
 ('62200000-0001-0000-0000-000000000002','62200000-0000-0000-0000-000000000002','WFC-2','Concurrency B','b@wfc.local',true,true);

CREATE OR REPLACE FUNCTION public.wf_test_try_instance(
 p_version UUID,p_subject UUID,p_org UUID,p_key UUID
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RETURN create_workflow_instance(p_version,'opaque_record',p_subject,p_org,p_key,NULL)::TEXT;
EXCEPTION WHEN unique_violation THEN RETURN 'unique_violation';
END $$;
REVOKE ALL ON FUNCTION public.wf_test_try_instance(UUID,UUID,UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wf_test_try_instance(UUID,UUID,UUID,UUID) TO authenticated;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 1. Same create command converges on one definition and first version.
SELECT dblink_send_query('w1',$q$SELECT definition_id::text||':'||version_id::text FROM create_workflow_definition('62200000-0000-0000-0000-000000000001','concurrent_flow','Concurrent Flow','opaque_record','{"nodes":[],"edges":[]}','62200000-1000-0000-0000-000000000001')$q$);
SELECT dblink_send_query('w2',$q$SELECT definition_id::text||':'||version_id::text FROM create_workflow_definition('62200000-0000-0000-0000-000000000001','concurrent_flow','Concurrent Flow','opaque_record','{"nodes":[],"edges":[]}','62200000-1000-0000-0000-000000000001')$q$);
CREATE TEMP TABLE wf_c1_result(v text); CREATE TEMP TABLE wf_c2_result(v text);
INSERT INTO wf_c1_result SELECT * FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wf_c2_result SELECT * FROM dblink_get_result('w2',false) AS t(v text);
DO $$ BEGIN IF (SELECT v FROM wf_c1_result)<>(SELECT v FROM wf_c2_result) OR (SELECT count(*) FROM workflow_definitions WHERE definition_key='concurrent_flow')<>1 THEN RAISE EXCEPTION 'definition idempotency race'; END IF; END $$;
INSERT INTO wf_concurrency_results VALUES(1,'concurrent definition retry converges');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

SET ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false);
SELECT publish_workflow_definition_version((SELECT v.id FROM workflow_definition_versions v JOIN workflow_definitions d ON d.id=v.definition_id WHERE d.definition_key='concurrent_flow'),0,'62200000-1000-0000-0000-000000000002');
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 2. Same instance command converges on one aggregate.
TRUNCATE wf_c1_result,wf_c2_result;
SELECT dblink_send_query('w1',$q$SELECT create_workflow_instance((SELECT active_version_id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'opaque_record','62200000-2000-0000-0000-000000000001','62200000-0000-0000-0000-000000000001','62200000-1000-0000-0000-000000000003',NULL)::text$q$);
SELECT dblink_send_query('w2',$q$SELECT create_workflow_instance((SELECT active_version_id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'opaque_record','62200000-2000-0000-0000-000000000001','62200000-0000-0000-0000-000000000001','62200000-1000-0000-0000-000000000003',NULL)::text$q$);
INSERT INTO wf_c1_result SELECT * FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wf_c2_result SELECT * FROM dblink_get_result('w2',false) AS t(v text);
DO $$ BEGIN IF (SELECT v FROM wf_c1_result)<>(SELECT v FROM wf_c2_result) OR (SELECT count(*) FROM workflow_instances WHERE subject_id='62200000-2000-0000-0000-000000000001')<>1 THEN RAISE EXCEPTION 'instance idempotency race'; END IF; END $$;
INSERT INTO wf_concurrency_results VALUES(2,'concurrent instance retry converges');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 3. Distinct commands for one active subject serialize to one valid winner.
TRUNCATE wf_c1_result,wf_c2_result;
SELECT dblink_send_query('w1',$q$SELECT wf_test_try_instance((SELECT active_version_id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'62200000-2000-0000-0000-000000000002','62200000-0000-0000-0000-000000000001','62200000-1000-0000-0000-000000000004')$q$);
SELECT dblink_send_query('w2',$q$SELECT wf_test_try_instance((SELECT active_version_id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'62200000-2000-0000-0000-000000000002','62200000-0000-0000-0000-000000000001','62200000-1000-0000-0000-000000000005')$q$);
INSERT INTO wf_c1_result SELECT * FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wf_c2_result SELECT * FROM dblink_get_result('w2',false) AS t(v text);
DO $$ BEGIN IF (SELECT count(*) FROM workflow_instances WHERE subject_id='62200000-2000-0000-0000-000000000002')<>1 OR (SELECT count(*) FROM (SELECT v FROM wf_c1_result UNION ALL SELECT v FROM wf_c2_result) x WHERE v='unique_violation')<>1 THEN RAISE EXCEPTION 'active subject race'; END IF; END $$;
INSERT INTO wf_concurrency_results VALUES(3,'competing active subject commands serialize');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 4. Concurrent version retry converges without duplicate draft numbers.
TRUNCATE wf_c1_result,wf_c2_result;
SELECT dblink_send_query('w1',$q$SELECT version_id::text FROM create_workflow_definition_version((SELECT id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'{"nodes":[],"edges":[],"revision":2}','62200000-1000-0000-0000-000000000006')$q$);
SELECT dblink_send_query('w2',$q$SELECT version_id::text FROM create_workflow_definition_version((SELECT id FROM workflow_definitions WHERE definition_key='concurrent_flow'),'{"nodes":[],"edges":[],"revision":2}','62200000-1000-0000-0000-000000000006')$q$);
INSERT INTO wf_c1_result SELECT * FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wf_c2_result SELECT * FROM dblink_get_result('w2',false) AS t(v text);
DO $$ BEGIN IF (SELECT v FROM wf_c1_result)<>(SELECT v FROM wf_c2_result) OR (SELECT count(*) FROM workflow_definition_versions v JOIN workflow_definitions d ON d.id=v.definition_id WHERE d.definition_key='concurrent_flow' AND v.status='draft')<>1 THEN RAISE EXCEPTION 'version race'; END IF; END $$;
INSERT INTO wf_concurrency_results VALUES(4,'concurrent version retry converges');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');

-- 5. A second organization uses independent lock keys and completes normally.
SELECT dblink_exec('w2','RESET ROLE'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"62200000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT count(*)::int FROM create_workflow_definition('62200000-0000-0000-0000-000000000002','other_org_flow','Other Org Flow','opaque_record','{"nodes":[],"edges":[]}','62200000-1000-0000-0000-000000000007')$q$) AS t(v int);
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM workflow_definitions WHERE definition_key='other_org_flow') THEN RAISE EXCEPTION 'unrelated organization'; END IF; END $$;
INSERT INTO wf_concurrency_results VALUES(5,'unrelated organization proceeds independently without deadlock');

SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP FUNCTION public.wf_test_try_instance(UUID,UUID,UUID,UUID);
DO $$ BEGIN IF (SELECT count(*) FROM wf_concurrency_results)<>5 THEN RAISE EXCEPTION 'Expected 5 scenarios'; END IF; END $$;
SELECT 'Workflow backend concurrency tests PASSED: 5/5' AS result;

ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE actor_id::text LIKE '62200000-%';
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_participants WHERE created_by::text LIKE '62200000-%';
DELETE FROM workflow_instances WHERE created_by::text LIKE '62200000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definitions SET active_version_id=NULL WHERE created_by::text LIKE '62200000-%';
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '62200000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '62200000-%';
DELETE FROM users WHERE id::text LIKE '62200000-%'; DELETE FROM auth.users WHERE id::text LIKE '62200000-%';
DELETE FROM organizations WHERE id::text LIKE '62200000-%';
DO $$ BEGIN
  IF NOT (SELECT dblink_preexisting FROM wf_extension_state) THEN
    EXECUTE 'DROP EXTENSION dblink';
  END IF;
END $$;
