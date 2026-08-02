-- CorLink — T3E.1 authenticated behavioral/concurrency test (30 scenarios)
-- Disposable/local PostgreSQL only. Creates fixed 7e... fixtures and removes them.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE t3e_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE t3e_one_side (id UUID NOT NULL);
GRANT SELECT, INSERT ON t3e_results, t3e_one_side TO authenticated;

-- Fixture hierarchy, identities, and tasks. All business rows are deleted at end.
INSERT INTO organizations (id,name,type,code) VALUES
 ('7e000000-0000-0000-0000-000000000001','T3E Org A','authority','T3EA'),
 ('7e000000-0000-0000-0000-000000000002','T3E Org B','authority','T3EB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('7e000000-0000-0000-0000-000000000011','T3E Division A','7e000000-0000-0000-0000-000000000001'),
 ('7e000000-0000-0000-0000-000000000012','T3E Division B','7e000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('7e000000-0000-0000-0000-000000000021','T3E Section A','T3ESA','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000011'),
 ('7e000000-0000-0000-0000-000000000022','T3E Section B','T3ESB','7e000000-0000-0000-0000-000000000002','7e000000-0000-0000-0000-000000000012');
INSERT INTO auth.users (id,email) VALUES
 ('7e000000-0001-0000-0000-000000000001','both@t3e.local'),
 ('7e000000-0001-0000-0000-000000000002','source@t3e.local'),
 ('7e000000-0001-0000-0000-000000000003','target@t3e.local'),
 ('7e000000-0001-0000-0000-000000000004','viewer@t3e.local'),
 ('7e000000-0001-0000-0000-000000000005','super@t3e.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','T3E-1','Both Manager','both@t3e.local',true,false),
 ('7e000000-0001-0000-0000-000000000002','7e000000-0000-0000-0000-000000000001','T3E-2','Source Manager','source@t3e.local',true,false),
 ('7e000000-0001-0000-0000-000000000003','7e000000-0000-0000-0000-000000000001','T3E-3','Target Manager','target@t3e.local',true,false),
 ('7e000000-0001-0000-0000-000000000004','7e000000-0000-0000-0000-000000000001','T3E-4','One Endpoint Viewer','viewer@t3e.local',true,false),
 ('7e000000-0001-0000-0000-000000000005','7e000000-0000-0000-0000-000000000001','T3E-5','Cross-org Super','super@t3e.local',true,true);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('7e000000-0001-0000-0000-000000000001','section','7e000000-0000-0000-0000-000000000021','staff',true,true),
 ('7e000000-0001-0000-0000-000000000002','section','7e000000-0000-0000-0000-000000000021','staff',true,true),
 ('7e000000-0001-0000-0000-000000000003','section','7e000000-0000-0000-0000-000000000021','staff',true,true),
 ('7e000000-0001-0000-0000-000000000004','section','7e000000-0000-0000-0000-000000000021','staff',true,true);

INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility) VALUES
 ('7e000000-1000-0000-0000-000000000001','T3E-A','A','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000002','T3E-B','B','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000003','T3E-C','C','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000004','T3E-D','D','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000005','T3E-E','E','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000006','T3E-F','F','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000007','T3E-G','G','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000008','T3E-H','H','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000009','T3E-I','I','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000010','T3E-J','J','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000014','T3E-K','K','open','normal','7e000000-0001-0000-0000-000000000001','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','private'),
 ('7e000000-1000-0000-0000-000000000011','T3E-S','Source-only','open','normal','7e000000-0001-0000-0000-000000000002','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','organization'),
 ('7e000000-1000-0000-0000-000000000012','T3E-T','Target-only','open','normal','7e000000-0001-0000-0000-000000000003','7e000000-0000-0000-0000-000000000001','7e000000-0000-0000-0000-000000000021','organization'),
 ('7e000000-1000-0000-0000-000000000013','T3E-X','Cross-org','open','normal','7e000000-0001-0000-0000-000000000005','7e000000-0000-0000-0000-000000000002','7e000000-0000-0000-0000-000000000022','private');
INSERT INTO task_assignments (task_id,user_id,assigned_by,is_active) VALUES
 ('7e000000-1000-0000-0000-000000000001','7e000000-0001-0000-0000-000000000004','7e000000-0001-0000-0000-000000000001',true);

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false);

-- 1-4: three canonical types and derived child label.
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000001','7e000000-1000-0000-0000-000000000002','related');
INSERT INTO t3e_results VALUES (1,'create related');
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000003','7e000000-1000-0000-0000-000000000004','duplicate');
INSERT INTO t3e_results VALUES (2,'create duplicate');
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000005','7e000000-1000-0000-0000-000000000006','parent');
INSERT INTO t3e_results VALUES (3,'create parent');
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM list_related_tasks('7e000000-1000-0000-0000-000000000006') WHERE relationship_type='child') THEN RAISE EXCEPTION 'child inverse missing'; END IF; END $$;
INSERT INTO t3e_results VALUES (4,'derived child label');

-- Expected-rejection helper pattern, scenarios 5-11.
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000007','7e000000-1000-0000-0000-000000000007','related'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (5,'self rejected');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000002','7e000000-1000-0000-0000-000000000001','related'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (6,'reverse symmetric rejected');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000003','7e000000-1000-0000-0000-000000000004','duplicate'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (7,'duplicate active rejected');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000006','7e000000-1000-0000-0000-000000000005','parent'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (8,'contradictory parent direction rejected');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000006','7e000000-1000-0000-0000-000000000005','parent'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (9,'direct parent cycle rejected');
SELECT remove_task_relationship((SELECT relationship_id FROM list_related_tasks('7e000000-1000-0000-0000-000000000005') WHERE related_task_id='7e000000-1000-0000-0000-000000000006'));
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000005','7e000000-1000-0000-0000-000000000006','parent');
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000006','7e000000-1000-0000-0000-000000000007','parent');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000007','7e000000-1000-0000-0000-000000000005','parent'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (10,'three-level indirect cycle rejected');
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000007','7e000000-1000-0000-0000-000000000008','parent');
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000008','7e000000-1000-0000-0000-000000000005','parent'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (11,'long indirect cycle rejected');

-- 12-14: real concurrent sessions. Exactly one operation may succeed.
RESET ROLE;
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SET ROLE authenticated;
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010','related')$q$);
SELECT dblink_send_query('c2',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010','related')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result uuid); SELECT * FROM dblink_get_result('c2',false) AS t(result uuid);
DO $$ BEGIN IF (SELECT count(*) FROM task_relationships WHERE removed_at IS NULL AND source_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010') AND target_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010'))<>1 THEN RAISE EXCEPTION 'concurrent duplicate count'; END IF; END $$;
INSERT INTO t3e_results VALUES (12,'concurrent duplicate leaves one row');
SELECT remove_task_relationship((SELECT id FROM task_relationships WHERE removed_at IS NULL AND source_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010') AND target_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010')));
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');
RESET ROLE;
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SET ROLE authenticated;
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT dblink_send_query('c1',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010','duplicate')$q$);
SELECT dblink_send_query('c2',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000010','7e000000-1000-0000-0000-000000000009','duplicate')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result uuid); SELECT * FROM dblink_get_result('c2',false) AS t(result uuid);
DO $$ BEGIN IF (SELECT count(*) FROM task_relationships WHERE removed_at IS NULL AND source_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010') AND target_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010'))<>1 THEN RAISE EXCEPTION 'concurrent reverse count'; END IF; END $$;
INSERT INTO t3e_results VALUES (13,'concurrent reverse symmetric leaves one row');
SELECT remove_task_relationship((SELECT id FROM task_relationships WHERE removed_at IS NULL AND source_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010') AND target_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010')));
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');
RESET ROLE;
SELECT dblink_connect('c1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('c2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SET ROLE authenticated;
SELECT dblink_exec('c1','SET ROLE authenticated'); SELECT dblink_exec('c2','SET ROLE authenticated');
SELECT * FROM dblink('c1',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('c2',$q$SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT create_task_relationship('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010','parent');
SELECT dblink_send_query('c1',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000010','7e000000-1000-0000-0000-000000000014','parent')$q$);
SELECT dblink_send_query('c2',$q$SELECT create_task_relationship('7e000000-1000-0000-0000-000000000014','7e000000-1000-0000-0000-000000000009','parent')$q$);
SELECT * FROM dblink_get_result('c1',false) AS t(result uuid); SELECT * FROM dblink_get_result('c2',false) AS t(result uuid);
-- Existing C duplicate D prevents the second edge independently; graph must remain acyclic.
DO $$ BEGIN IF EXISTS (WITH RECURSIVE walk(root,node) AS (SELECT source_task_id,target_task_id FROM task_relationships WHERE removed_at IS NULL AND relationship_type='parent' UNION SELECT w.root,tr.target_task_id FROM walk w JOIN task_relationships tr ON tr.source_task_id=w.node WHERE tr.removed_at IS NULL AND tr.relationship_type='parent') SELECT 1 FROM walk WHERE root=node) THEN RAISE EXCEPTION 'concurrent cycle created'; END IF; END $$;
DO $$ BEGIN IF (SELECT count(*) FROM task_relationships WHERE removed_at IS NULL AND relationship_type='parent' AND source_task_id IN ('7e000000-1000-0000-0000-000000000009','7e000000-1000-0000-0000-000000000010','7e000000-1000-0000-0000-000000000014'))<>2 THEN RAISE EXCEPTION 'expected exactly one concurrent parent edge'; END IF; END $$;
INSERT INTO t3e_results VALUES (14,'concurrent operations cannot create parent cycle');
SELECT dblink_disconnect('c1'); SELECT dblink_disconnect('c2');

-- 15-20 authorization and non-inference.
INSERT INTO t3e_results VALUES (15,'both-task manager can create');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000011','7e000000-1000-0000-0000-000000000012','related'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (16,'source-only manager denied');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000003"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000011','7e000000-1000-0000-0000-000000000012','related'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (17,'target-only manager denied');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000002"}',false);
INSERT INTO t3e_results VALUES (18,'view-target manage-source denied');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000005"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_relationship('7e000000-1000-0000-0000-000000000001','7e000000-1000-0000-0000-000000000013','related'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES (19,'cross-organization rejected');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000004"}',false);
DO $$ BEGIN IF EXISTS (SELECT 1 FROM list_related_tasks('7e000000-1000-0000-0000-000000000001')) OR EXISTS (SELECT 1 FROM task_relationships) OR EXISTS (SELECT 1 FROM audit_logs WHERE record_type='task_relationship') THEN RAISE EXCEPTION 'one-endpoint inference'; END IF; END $$;
INSERT INTO t3e_results VALUES (20,'one-endpoint viewer cannot infer');

-- 21-23 direct writes denied.
DO $$ BEGIN BEGIN INSERT INTO task_relationships(source_task_id,target_task_id,relationship_type,created_by) VALUES('7e000000-1000-0000-0000-000000000001','7e000000-1000-0000-0000-000000000002','related',auth.uid()); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$; INSERT INTO t3e_results VALUES(21,'direct insert denied');
DO $$ BEGIN BEGIN UPDATE task_relationships SET removed_at=now(); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$; INSERT INTO t3e_results VALUES(22,'direct update denied');
DO $$ BEGIN BEGIN DELETE FROM task_relationships; RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$; INSERT INTO t3e_results VALUES(23,'direct delete denied');

-- 24-27 removal, one-endpoint denial, status preservation, confidential audit.
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000005"}',false);
INSERT INTO t3e_one_side SELECT create_task_relationship('7e000000-1000-0000-0000-000000000011','7e000000-1000-0000-0000-000000000012','related');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM remove_task_relationship((SELECT id FROM t3e_one_side)); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3e_results VALUES(25,'one-endpoint manager cannot remove');
SELECT set_config('request.jwt.claims','{"sub":"7e000000-0001-0000-0000-000000000005"}',false);
SELECT remove_task_relationship((SELECT id FROM t3e_one_side));
DO $$ BEGIN IF (SELECT removed_at IS NULL FROM task_relationships WHERE id=(SELECT id FROM t3e_one_side)) THEN RAISE EXCEPTION 'not removed'; END IF; END $$;
INSERT INTO t3e_results VALUES(24,'authorized removal soft-removes');
DO $$ BEGIN IF EXISTS (SELECT 1 FROM tasks WHERE id IN ('7e000000-1000-0000-0000-000000000011','7e000000-1000-0000-0000-000000000012') AND status<>'open') THEN RAISE EXCEPTION 'status changed'; END IF; END $$;
INSERT INTO t3e_results VALUES(26,'removal preserves task status');
DO $$ BEGIN IF (SELECT count(*) FROM audit_logs WHERE record_type='task_relationship' AND record_id=(SELECT id FROM t3e_one_side) AND action IN ('task_linked','task_unlinked') AND notes !~ '^type=(related|duplicate|parent)$')<>0 OR (SELECT count(*) FROM audit_logs WHERE record_type='task_relationship' AND record_id=(SELECT id FROM t3e_one_side))<>2 THEN RAISE EXCEPTION 'audit incorrect'; END IF; END $$;
INSERT INTO t3e_results VALUES(27,'audit rows correct and non-confidential');

-- 28-30 regressions: standalone Tasks, module links, and attachments still exist.
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM tasks WHERE id='7e000000-1000-0000-0000-000000000001') THEN RAISE EXCEPTION 'task missing'; END IF; END $$; INSERT INTO t3e_results VALUES(28,'standalone tasks valid');
DO $$ BEGIN IF to_regclass('public.task_links') IS NULL OR to_regprocedure('list_task_request_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_meeting_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_internal_collaboration_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_entry_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_prisoner_letter_links(uuid,integer,integer)') IS NULL THEN RAISE EXCEPTION 'module regression'; END IF; END $$; INSERT INTO t3e_results VALUES(29,'task_links integrations valid');
DO $$ BEGIN IF to_regclass('public.attachments') IS NULL OR NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task''%' FROM pg_constraint WHERE conname='attachments_record_type_check') THEN RAISE EXCEPTION 'attachments regression'; END IF; END $$; INSERT INTO t3e_results VALUES(30,'task attachments valid');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM t3e_results)<>30 OR (SELECT min(scenario) FROM t3e_results)<>1 OR (SELECT max(scenario) FROM t3e_results)<>30 THEN RAISE EXCEPTION 'Expected 30 passing scenarios, got %',(SELECT count(*) FROM t3e_results); END IF; RAISE NOTICE 'TASK RELATIONSHIPS: 30 PASSED, 0 FAILED'; END $$;

-- Explicit disposable-fixture cleanup as superuser.
DELETE FROM audit_logs WHERE user_id::text LIKE '7e000000-0001-%';
DELETE FROM task_relationships WHERE source_task_id::text LIKE '7e000000-1000-%' OR target_task_id::text LIKE '7e000000-1000-%';
DELETE FROM task_assignments WHERE task_id::text LIKE '7e000000-1000-%';
DELETE FROM tasks WHERE id::text LIKE '7e000000-1000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '7e000000-0001-%';
DELETE FROM users WHERE id::text LIKE '7e000000-0001-%';
DELETE FROM auth.users WHERE id::text LIKE '7e000000-0001-%';
DELETE FROM sections WHERE id::text LIKE '7e000000-0000-%';
DELETE FROM divisions WHERE id::text LIKE '7e000000-0000-%';
DELETE FROM organizations WHERE id::text LIKE '7e000000-0000-%';
