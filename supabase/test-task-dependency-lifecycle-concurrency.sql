-- CorLink - T3F.2 repeatable lifecycle concurrency suite (5 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE t3f2_concurrency_results(scenario INTEGER PRIMARY KEY,name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('f6000000-0000-0000-0000-000000000001','T3F2 Concurrency A','authority','T3F2CA'),
 ('f6000000-0000-0000-0000-000000000002','T3F2 Concurrency B','authority','T3F2CB');
INSERT INTO auth.users(id,email) VALUES ('f6000000-0001-0000-0000-000000000001','concurrency@t3f2.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','T3F2-C1','Concurrency Manager','concurrency@t3f2.local',true,true);
INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,visibility) VALUES
 ('f6000000-1000-0000-0000-000000000001','T3F2-C-D1','Completion race dependent','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000002','T3F2-C-P1','Completion race prerequisite','in_progress','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000003','T3F2-C-D2','Creation race dependent','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000004','T3F2-C-P2','Creation race prerequisite','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000005','T3F2-C-D3','Removal race dependent','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000006','T3F2-C-P3','Removal race prerequisite','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000007','T3F2-C-U1','Deadlock probe one','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-1000-0000-0000-000000000008','T3F2-C-U2','Deadlock probe two','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','private'),
 ('f6000000-2000-0000-0000-000000000001','T3F2-C-OB','Unrelated organization','open','normal','f6000000-0001-0000-0000-000000000001','f6000000-0000-0000-0000-000000000002','private');
INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by) VALUES
 ('f6000000-1000-0000-0000-000000000001','f6000000-1000-0000-0000-000000000002','f6000000-0000-0000-0000-000000000001','f6000000-0001-0000-0000-000000000001'),
 ('f6000000-1000-0000-0000-000000000005','f6000000-1000-0000-0000-000000000006','f6000000-0000-0000-0000-000000000001','f6000000-0001-0000-0000-000000000001');

-- 1. Prerequisite completion and dependent start serialize. A started
-- dependent always observes the prerequisite as completed.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1',$q$SELECT complete_task('f6000000-1000-0000-0000-000000000002')$q$);
SELECT dblink_send_query('c2',$q$SELECT update_task('f6000000-1000-0000-0000-000000000001',p_status:='in_progress')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result TEXT);
SELECT * FROM dblink_get_result('c2',false) AS t(result TEXT);
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f6000000-1000-0000-0000-000000000001')='in_progress' AND (SELECT status FROM tasks WHERE id='f6000000-1000-0000-0000-000000000002')<>'completed' THEN RAISE EXCEPTION 'dependent started before prerequisite resolved'; END IF; END $$;
INSERT INTO t3f2_concurrency_results VALUES(1,'completion/start race is serially valid');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 2. Dependency creation and start cannot leave an in-progress Task with a
-- newly active unresolved edge.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1',$q$SELECT (create_task_dependency('f6000000-1000-0000-0000-000000000003','f6000000-1000-0000-0000-000000000004')).id$q$);
SELECT dblink_send_query('c2',$q$SELECT update_task('f6000000-1000-0000-0000-000000000003',p_status:='in_progress')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result TEXT);
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f6000000-1000-0000-0000-000000000003')='in_progress' AND EXISTS(SELECT 1 FROM task_dependencies WHERE dependent_task_id='f6000000-1000-0000-0000-000000000003' AND removed_at IS NULL) THEN RAISE EXCEPTION 'creation/start bypass'; END IF; END $$;
INSERT INTO t3f2_concurrency_results VALUES(2,'creation/start race is serially valid');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 3. Removal and start serialize to either open-after-removal or
-- in-progress-after-removal; the edge is never left active after a start.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1',$q$SELECT (remove_task_dependency((SELECT id FROM task_dependencies WHERE dependent_task_id='f6000000-1000-0000-0000-000000000005' AND removed_at IS NULL))).id$q$);
SELECT dblink_send_query('c2',$q$SELECT update_task('f6000000-1000-0000-0000-000000000005',p_status:='in_progress')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result TEXT);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM task_dependencies WHERE dependent_task_id='f6000000-1000-0000-0000-000000000005' AND removed_at IS NULL) OR (SELECT status FROM tasks WHERE id='f6000000-1000-0000-0000-000000000005') NOT IN ('open','in_progress') THEN RAISE EXCEPTION 'removal/start outcome invalid'; END IF; END $$;
INSERT INTO t3f2_concurrency_results VALUES(3,'removal/start race is serially valid');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 4. Same-organization lifecycle calls share graph->Task lock ordering and
-- finish without deadlock.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_exec('c1','SET statement_timeout=''5000ms'''); SELECT dblink_exec('c2','SET statement_timeout=''5000ms''');
SELECT dblink_send_query('c1',$q$SELECT update_task('f6000000-1000-0000-0000-000000000007',p_status:='in_progress')$q$);
SELECT dblink_send_query('c2',$q$SELECT update_task('f6000000-1000-0000-0000-000000000008',p_status:='in_progress')$q$);
SELECT * FROM dblink_get_result('c1',true) AS t(result TEXT);
SELECT * FROM dblink_get_result('c2',true) AS t(result TEXT);
DO $$ BEGIN IF (SELECT count(*) FROM tasks WHERE id IN ('f6000000-1000-0000-0000-000000000007','f6000000-1000-0000-0000-000000000008') AND status='in_progress')<>2 THEN RAISE EXCEPTION 'same-org lifecycle calls did not finish'; END IF; END $$;
INSERT INTO t3f2_concurrency_results VALUES(4,'deterministic lock order has no deadlock');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 5. An Org A graph lock does not block an Org B lifecycle action.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','BEGIN');
SELECT * FROM dblink('c1',$q$SELECT 'locked'::text FROM (SELECT pg_advisory_xact_lock(hashtextextended('task_dependencies:f6000000-0000-0000-0000-000000000001',0))) held$q$) AS t(v text);
SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f6000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_exec('c2','SET statement_timeout=''2000ms''');
SELECT * FROM dblink('c2',$q$SELECT update_task('f6000000-2000-0000-0000-000000000001',p_status:='in_progress')$q$) AS t(result TEXT);
SELECT dblink_exec('c1','ROLLBACK');
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f6000000-2000-0000-0000-000000000001')<>'in_progress' THEN RAISE EXCEPTION 'unrelated org blocked'; END IF; END $$;
INSERT INTO t3f2_concurrency_results VALUES(5,'unrelated organization proceeds independently');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

DO $$ BEGIN IF (SELECT count(*) FROM t3f2_concurrency_results)<>5 THEN RAISE EXCEPTION 'Expected 5 concurrency passes'; END IF; RAISE NOTICE 'TASK DEPENDENCY LIFECYCLE CONCURRENCY: 5 PASSED, 0 FAILED'; END $$;

DELETE FROM notifications WHERE user_id='f6000000-0001-0000-0000-000000000001' OR record_id::text LIKE 'f6000000-%';
DELETE FROM audit_logs WHERE user_id='f6000000-0001-0000-0000-000000000001' OR record_id::text LIKE 'f6000000-%';
DELETE FROM task_dependency_waivers WHERE dependency_id IN (SELECT id FROM task_dependencies WHERE dependent_task_id::text LIKE 'f6000000-%');
DELETE FROM task_dependencies WHERE dependent_task_id::text LIKE 'f6000000-%' OR prerequisite_task_id::text LIKE 'f6000000-%';
DELETE FROM tasks WHERE id::text LIKE 'f6000000-%';
DELETE FROM users WHERE id='f6000000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='f6000000-0001-0000-0000-000000000001';
DELETE FROM organizations WHERE id::text LIKE 'f6000000-%';
