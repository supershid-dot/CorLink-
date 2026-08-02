-- CorLink — T3F.1 repeatable concurrency suite (6 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE t3f1_concurrency_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('f2000000-0000-0000-0000-000000000001','T3F1 Concurrency A','authority','T3F1CA'),
 ('f2000000-0000-0000-0000-000000000002','T3F1 Concurrency B','authority','T3F1CB');
INSERT INTO auth.users(id,email) VALUES ('f2000000-0001-0000-0000-000000000001','concurrency@t3f1.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','T3F1-C1','Concurrency Manager','concurrency@t3f1.local',true,true);
INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,visibility) VALUES
 ('f2000000-1000-0000-0000-000000000001','T3F1-CA','CA','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','private'),
 ('f2000000-1000-0000-0000-000000000002','T3F1-CB','CB','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','private'),
 ('f2000000-1000-0000-0000-000000000003','T3F1-CC','CC','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','private'),
 ('f2000000-1000-0000-0000-000000000004','T3F1-CD','CD','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000001','private'),
 ('f2000000-2000-0000-0000-000000000001','T3F1-OA','OA','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002','private'),
 ('f2000000-2000-0000-0000-000000000002','T3F1-OB','OB','open','normal','f2000000-0001-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002','private');

-- Connect as the database owner, then execute application calls as authenticated.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 1. Concurrent duplicate directed inserts leave one active row.
SELECT dblink_send_query('c1',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002')).id$q$);
SELECT dblink_send_query('c2',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002')).id$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result UUID);
DO $$ BEGIN IF (SELECT count(*) FROM task_dependencies WHERE dependent_task_id='f2000000-1000-0000-0000-000000000001' AND prerequisite_task_id='f2000000-1000-0000-0000-000000000002' AND removed_at IS NULL)<>1 THEN RAISE EXCEPTION 'concurrent duplicate count'; END IF; END $$;
INSERT INTO t3f1_concurrency_results VALUES(1,'concurrent duplicate leaves one active row');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- Fresh sessions after an expected async error.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false);
SELECT (remove_task_dependency((SELECT id FROM task_dependencies WHERE dependent_task_id='f2000000-1000-0000-0000-000000000001' AND prerequisite_task_id='f2000000-1000-0000-0000-000000000002' AND removed_at IS NULL))).id;
RESET ROLE;

-- 2. Opposite directions cannot form a two-node cycle.
SELECT dblink_send_query('c1',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002')).id$q$);
SELECT dblink_send_query('c2',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000002','f2000000-1000-0000-0000-000000000001')).id$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result UUID);
DO $$ BEGIN IF (SELECT count(*) FROM task_dependencies WHERE dependent_task_id IN ('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002') AND prerequisite_task_id IN ('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002') AND removed_at IS NULL)<>1 THEN RAISE EXCEPTION 'opposite direction count'; END IF; END $$;
INSERT INTO t3f1_concurrency_results VALUES(2,'concurrent opposite directions cannot form cycle');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- Normalize graph for the three-node race.
DELETE FROM audit_logs WHERE record_type='task_dependency';
DELETE FROM task_dependencies;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false);
SELECT create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002');
RESET ROLE;
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- 3. Exactly one of B->C and C->A can join existing A->B.
SELECT dblink_send_query('c1',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000002','f2000000-1000-0000-0000-000000000003')).id$q$);
SELECT dblink_send_query('c2',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000003','f2000000-1000-0000-0000-000000000001')).id$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result UUID);
DO $$ BEGIN
  IF (SELECT count(*) FROM task_dependencies WHERE removed_at IS NULL)<>2
     OR EXISTS (
       WITH RECURSIVE walk(root,node) AS (
         SELECT dependent_task_id,prerequisite_task_id FROM task_dependencies WHERE removed_at IS NULL
         UNION
         SELECT w.root,td.prerequisite_task_id FROM walk w JOIN task_dependencies td ON td.dependent_task_id=w.node WHERE td.removed_at IS NULL
       ) SELECT 1 FROM walk WHERE root=node
     ) THEN RAISE EXCEPTION 'three-node race inconsistent';
  END IF;
END $$;
INSERT INTO t3f1_concurrency_results VALUES(3,'concurrent three-node cycle prevented');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 4. Removal/recreation serializes and remains uniquely recoverable.
DELETE FROM audit_logs WHERE record_type='task_dependency'; DELETE FROM task_dependencies;
SET ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false);
SELECT create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002'); RESET ROLE;
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1','SELECT (remove_task_dependency((SELECT id FROM task_dependencies WHERE dependent_task_id=''f2000000-1000-0000-0000-000000000001'' AND prerequisite_task_id=''f2000000-1000-0000-0000-000000000002'' AND removed_at IS NULL))).id');
SELECT dblink_send_query('c2',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002')).id$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',false) AS t(result UUID);
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');
DO $$ BEGIN IF (SELECT count(*) FROM task_dependencies WHERE dependent_task_id='f2000000-1000-0000-0000-000000000001' AND prerequisite_task_id='f2000000-1000-0000-0000-000000000002' AND removed_at IS NULL)>1 THEN RAISE EXCEPTION 'remove/recreate duplicate'; END IF; END $$;
SET ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM task_dependencies WHERE dependent_task_id='f2000000-1000-0000-0000-000000000001' AND prerequisite_task_id='f2000000-1000-0000-0000-000000000002' AND removed_at IS NULL) THEN PERFORM create_task_dependency('f2000000-1000-0000-0000-000000000001','f2000000-1000-0000-0000-000000000002'); END IF; END $$;
RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM task_dependencies WHERE dependent_task_id='f2000000-1000-0000-0000-000000000001' AND prerequisite_task_id='f2000000-1000-0000-0000-000000000002' AND removed_at IS NULL)<>1 THEN RAISE EXCEPTION 'remove/recreate not recoverable'; END IF; END $$;
INSERT INTO t3f1_concurrency_results VALUES(4,'concurrent remove/recreate remains consistent');

-- 5. Holding Org A's exact graph lock does not block Org B.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','BEGIN');
SELECT * FROM dblink('c1',$q$SELECT 'locked'::text FROM (SELECT pg_advisory_xact_lock(hashtextextended('task_dependencies:f2000000-0000-0000-0000-000000000001',0))) lock_acquired$q$) AS t(v text);
SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_exec('c2','SET statement_timeout=''2000ms''');
SELECT * FROM dblink('c2',$q$SELECT (create_task_dependency('f2000000-2000-0000-0000-000000000001','f2000000-2000-0000-0000-000000000002')).id$q$) AS t(result UUID);
SELECT dblink_exec('c1','ROLLBACK');
INSERT INTO t3f1_concurrency_results VALUES(5,'organization lock does not block unrelated organization');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 6. Same-org operations serialize behind one key and complete without deadlock.
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"f2000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_exec('c1','SET statement_timeout=''5000ms'''); SELECT dblink_exec('c2','SET statement_timeout=''5000ms''');
SELECT dblink_send_query('c1',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000004','f2000000-1000-0000-0000-000000000001')).id$q$);
SELECT dblink_send_query('c2',$q$SELECT (create_task_dependency('f2000000-1000-0000-0000-000000000004','f2000000-1000-0000-0000-000000000002')).id$q$);
SELECT * FROM dblink_get_result('c1',true) AS t(result UUID);
SELECT * FROM dblink_get_result('c2',true) AS t(result UUID);
INSERT INTO t3f1_concurrency_results VALUES(6,'single-key lock ordering completes without deadlock');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

DO $$ BEGIN IF (SELECT count(*) FROM t3f1_concurrency_results)<>6 THEN RAISE EXCEPTION 'Expected 6 concurrency passes'; END IF; RAISE NOTICE 'TASK DEPENDENCY CONCURRENCY: 6 PASSED, 0 FAILED'; END $$;

DELETE FROM audit_logs WHERE user_id='f2000000-0001-0000-0000-000000000001';
DELETE FROM task_dependency_waivers WHERE dependency_id IN (SELECT id FROM task_dependencies WHERE dependent_task_id::text LIKE 'f2000000-%');
DELETE FROM task_dependencies WHERE dependent_task_id::text LIKE 'f2000000-%' OR prerequisite_task_id::text LIKE 'f2000000-%';
DELETE FROM tasks WHERE id::text LIKE 'f2000000-%';
DELETE FROM users WHERE id='f2000000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='f2000000-0001-0000-0000-000000000001';
DELETE FROM organizations WHERE id::text LIKE 'f2000000-%';
