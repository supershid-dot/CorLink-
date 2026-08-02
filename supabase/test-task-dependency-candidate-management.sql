-- CorLink — T3F.2A authenticated behavioral/RLS suite (25 scenarios)
-- Disposable local PostgreSQL only. Creates fixed f7... fixtures and removes them.
\set ON_ERROR_STOP on

CREATE TEMP TABLE t3f2a_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON t3f2a_results TO authenticated;

INSERT INTO organizations (id,name,type,code) VALUES
 ('f7000000-0000-0000-0000-000000000001','T3F2A Org A','authority','T3F2AA'),
 ('f7000000-0000-0000-0000-000000000002','T3F2A Org B','authority','T3F2AB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('f7000000-0000-0000-0000-000000000011','T3F2A Division A','f7000000-0000-0000-0000-000000000001'),
 ('f7000000-0000-0000-0000-000000000012','T3F2A Division B','f7000000-0000-0000-0000-000000000001'),
 ('f7000000-0000-0000-0000-000000000013','T3F2A Division X','f7000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('f7000000-0000-0000-0000-000000000021','T3F2A Section A','T3F2ASA','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000011'),
 ('f7000000-0000-0000-0000-000000000022','T3F2A Section B','T3F2ASB','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000012'),
 ('f7000000-0000-0000-0000-000000000023','T3F2A Section X','T3F2ASX','f7000000-0000-0000-0000-000000000002','f7000000-0000-0000-0000-000000000013');

INSERT INTO auth.users (id,email) VALUES
 ('f7000000-0001-0000-0000-000000000001','both@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000002','current@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000003','candidate@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000004','viewer@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000005','supervisor@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000006','unrelated@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000007','inactive-auth@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000008','cross@t3f2a.local'),
 ('f7000000-0001-0000-0000-000000000009','assignee@t3f2a.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','T3F2A-1','Both Manager','both@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000002','f7000000-0000-0000-0000-000000000001','T3F2A-2','Current Manager','current@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','T3F2A-3','Candidate Manager','candidate@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000004','f7000000-0000-0000-0000-000000000001','T3F2A-4','View Only','viewer@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000005','f7000000-0000-0000-0000-000000000001','T3F2A-5','Scoped Supervisor','supervisor@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000006','f7000000-0000-0000-0000-000000000001','T3F2A-6','Unrelated Staff','unrelated@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000007','f7000000-0000-0000-0000-000000000001','T3F2A-7','Inactive Assignment','inactive-auth@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000008','f7000000-0000-0000-0000-000000000002','T3F2A-8','Cross Org','cross@t3f2a.local',true,false),
 ('f7000000-0001-0000-0000-000000000009','f7000000-0000-0000-0000-000000000001','T3F2A-9','Active Assignee','assignee@t3f2a.local',true,false);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('f7000000-0001-0000-0000-000000000001','section','f7000000-0000-0000-0000-000000000021','staff',true,true),
 ('f7000000-0001-0000-0000-000000000002','section','f7000000-0000-0000-0000-000000000021','staff',true,true),
 ('f7000000-0001-0000-0000-000000000003','section','f7000000-0000-0000-0000-000000000021','staff',true,true),
 ('f7000000-0001-0000-0000-000000000004','section','f7000000-0000-0000-0000-000000000021','staff',true,true),
 ('f7000000-0001-0000-0000-000000000005','section','f7000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('f7000000-0001-0000-0000-000000000006','section','f7000000-0000-0000-0000-000000000022','staff',true,true),
 ('f7000000-0001-0000-0000-000000000007','section','f7000000-0000-0000-0000-000000000021','staff',true,true),
 ('f7000000-0001-0000-0000-000000000008','section','f7000000-0000-0000-0000-000000000023','staff',true,true),
 ('f7000000-0001-0000-0000-000000000009','section','f7000000-0000-0000-0000-000000000021','staff',true,true);

INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility) VALUES
 ('f7000000-1000-0000-0000-000000000001','T3F2A-CUR-0','Primary current','open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000002','T3F2A-CAN-0','Picker candidate title','open','high','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000003','T3F2A-CUR-1','Current-only managed','open','normal','f7000000-0001-0000-0000-000000000002','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000004','T3F2A-CAN-1','Candidate-only managed','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000005','T3F2A-CAN-2','Creator candidate','open','normal','f7000000-0001-0000-0000-000000000002','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000006','T3F2A-CUR-A','Assignee current','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000007','T3F2A-CAN-A','Assignee candidate','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000008','T3F2A-CUR-S','Supervisor current','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','section'),
 ('f7000000-1000-0000-0000-000000000009','T3F2A-CAN-S','Supervisor candidate','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','section'),
 ('f7000000-1000-0000-0000-000000000010','T3F2A-CUR-I','Inactive current','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000011','T3F2A-CAN-I','Inactive candidate','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','organization'),
 ('f7000000-1000-0000-0000-000000000012','T3F2A-HIDDEN','Hidden candidate','open','normal','f7000000-0001-0000-0000-000000000003','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000013','T3F2A-CROSS','Cross candidate','open','normal','f7000000-0001-0000-0000-000000000008','f7000000-0000-0000-0000-000000000002','f7000000-0000-0000-0000-000000000023','organization'),
 ('f7000000-1000-0000-0000-000000000014','T3F2A-CUR-F','Forward current','open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000015','T3F2A-CAN-F','Forward candidate','open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000016','T3F2A-CUR-R','Reverse current','open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'),
 ('f7000000-1000-0000-0000-000000000017','T3F2A-CAN-R','Reverse candidate','open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private');
INSERT INTO task_assignments (task_id,user_id,assigned_by,is_active) VALUES
 ('f7000000-1000-0000-0000-000000000006','f7000000-0001-0000-0000-000000000009','f7000000-0001-0000-0000-000000000003',true),
 ('f7000000-1000-0000-0000-000000000007','f7000000-0001-0000-0000-000000000009','f7000000-0001-0000-0000-000000000003',true),
 ('f7000000-1000-0000-0000-000000000010','f7000000-0001-0000-0000-000000000007','f7000000-0001-0000-0000-000000000003',false),
 ('f7000000-1000-0000-0000-000000000011','f7000000-0001-0000-0000-000000000007','f7000000-0001-0000-0000-000000000003',false);
INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility)
SELECT ('f7000000-2000-0000-0000-' || lpad(g::text,12,'0'))::uuid,
       'T3F2A-L' || lpad(g::text,3,'0'), 'Limit candidate ' || lpad(g::text,3,'0'),
       'open','normal','f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000021','private'
FROM generate_series(1,55) g;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000001"}',false);

DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-CAN-0',20) WHERE id='f7000000-1000-0000-0000-000000000002') THEN RAISE EXCEPTION 'both-manager candidate missing'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(1,'manager of current and candidate sees candidate');

SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-1',20)) THEN RAISE EXCEPTION 'view-only candidate leaked'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(2,'current manager cannot see view-only candidate');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000003"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-1',20)) THEN RAISE EXCEPTION 'unmanageable current Task allowed picker'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(3,'candidate manager cannot search from view-only current');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000004"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-1',20)) THEN RAISE EXCEPTION 'view-only actor received candidate'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(4,'viewer managing neither sees no candidate');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-2',20)) THEN RAISE EXCEPTION 'creator candidate missing'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(5,'creator management qualifies');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000009"}',false);
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000006','T3F2A-CAN-A',20)) THEN RAISE EXCEPTION 'active assignee candidate missing'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(6,'active assignee management qualifies');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000005"}',false);
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000008','T3F2A-CAN-S',20)) THEN RAISE EXCEPTION 'scoped supervisor candidate missing'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(7,'scoped supervisor management qualifies');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000006"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-1',20)) THEN RAISE EXCEPTION 'same-org unrelated staff received candidate'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(8,'same-org unrelated staff sees no candidate');

SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-CROSS',20)) THEN RAISE EXCEPTION 'cross-org candidate leaked'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(9,'cross-organization candidate excluded');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-HIDDEN',20)) THEN RAISE EXCEPTION 'hidden candidate leaked'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(10,'hidden candidate excluded');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000007"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000010','T3F2A-CAN-I',20)) THEN RAISE EXCEPTION 'inactive assignments qualified'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(11,'inactive authorization does not qualify');

SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-CUR-0',20)) THEN RAISE EXCEPTION 'current Task returned'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(12,'current Task excluded');
SELECT create_task_dependency('f7000000-1000-0000-0000-000000000014','f7000000-1000-0000-0000-000000000015');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000014','T3F2A-CAN-F',20)) THEN RAISE EXCEPTION 'existing prerequisite returned'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(13,'existing prerequisite excluded');
SELECT create_task_dependency('f7000000-1000-0000-0000-000000000017','f7000000-1000-0000-0000-000000000016');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000016','T3F2A-CAN-R',20)) THEN RAISE EXCEPTION 'existing reverse dependent returned'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(14,'existing reverse edge excluded');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-CAN-0',20) WHERE task_number='T3F2A-CAN-0') THEN RAISE EXCEPTION 'exact number search changed'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(15,'exact Task number search preserved');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','Picker candidate',20) WHERE id='f7000000-1000-0000-0000-000000000002') THEN RAISE EXCEPTION 'title prefix search changed'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(16,'title prefix search preserved');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','',20)) OR (SELECT count(*) FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T',3))>3 THEN RAISE EXCEPTION 'empty/short bounded behavior changed'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(17,'empty and short search behavior bounded');
DO $$ BEGIN IF (SELECT count(*) FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-L',100))<>50 THEN RAISE EXCEPTION 'limit clamp changed'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(18,'result limit clamps to fifty');
DO $$ DECLARE a TEXT[]; b TEXT[]; BEGIN SELECT array_agg(task_number) INTO a FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-L',50); SELECT array_agg(task_number ORDER BY task_number,title,id) INTO b FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000001','T3F2A-L',50); IF a IS DISTINCT FROM b THEN RAISE EXCEPTION 'ordering changed'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(19,'deterministic ordering preserved');
SELECT create_task_dependency('f7000000-1000-0000-0000-000000000001','f7000000-1000-0000-0000-000000000002');
INSERT INTO t3f2a_results VALUES(20,'returned candidate creates dependency successfully');
SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f7000000-1000-0000-0000-000000000003','f7000000-1000-0000-0000-000000000004'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2a_results VALUES(21,'view-only candidate cannot be created');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f7000000-1000-0000-0000-000000000003','T3F2A-CAN-1',50)) THEN RAISE EXCEPTION 'unauthorized result count inferable'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(22,'hidden candidate count not inferable');

SELECT set_config('request.jwt.claims','{"sub":"f7000000-0001-0000-0000-000000000001"}',false);
DO $$ DECLARE s RECORD; BEGIN SELECT * INTO s FROM get_task_dependency_lifecycle_state('f7000000-1000-0000-0000-000000000001'); IF NOT s.is_blocked OR s.unresolved_prerequisite_count<>1 THEN RAISE EXCEPTION 'lifecycle state regression'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(23,'dependency lifecycle state remains valid');
DO $$ DECLARE rid UUID; BEGIN rid:=create_task_relationship('f7000000-1000-0000-0000-000000000001','f7000000-1000-0000-0000-000000000002','related'); PERFORM remove_task_relationship(rid); END $$;
INSERT INTO t3f2a_results VALUES(24,'Task Relationships remain valid');
DO $$ BEGIN IF to_regclass('public.task_links') IS NULL OR to_regclass('public.attachments') IS NULL OR to_regprocedure('list_task_request_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_meeting_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_internal_collaboration_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_entry_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_prisoner_letter_links(uuid,integer,integer)') IS NULL THEN RAISE EXCEPTION 'module links or attachments regression'; END IF; END $$;
INSERT INTO t3f2a_results VALUES(25,'module links and attachments remain valid');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM t3f2a_results)<>25 OR (SELECT min(scenario) FROM t3f2a_results)<>1 OR (SELECT max(scenario) FROM t3f2a_results)<>25 THEN RAISE EXCEPTION 'Expected 25 passing scenarios, got %',(SELECT count(*) FROM t3f2a_results); END IF; RAISE NOTICE 'TASK DEPENDENCY CANDIDATE MANAGEMENT: 25 PASSED, 0 FAILED'; END $$;

DELETE FROM audit_logs WHERE user_id::text LIKE 'f7000000-0001-%';
DELETE FROM task_relationships WHERE source_task_id::text LIKE 'f7000000-1000-%' OR target_task_id::text LIKE 'f7000000-1000-%';
DELETE FROM task_dependency_waivers WHERE dependency_id IN (SELECT id FROM task_dependencies WHERE dependent_task_id::text LIKE 'f7000000-1000-%' OR prerequisite_task_id::text LIKE 'f7000000-1000-%');
DELETE FROM task_dependencies WHERE dependent_task_id::text LIKE 'f7000000-1000-%' OR prerequisite_task_id::text LIKE 'f7000000-1000-%';
DELETE FROM task_assignments WHERE task_id::text LIKE 'f7000000-1000-%' OR task_id::text LIKE 'f7000000-2000-%';
DELETE FROM tasks WHERE id::text LIKE 'f7000000-1000-%' OR id::text LIKE 'f7000000-2000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE 'f7000000-0001-%';
DELETE FROM users WHERE id::text LIKE 'f7000000-0001-%';
DELETE FROM auth.users WHERE id::text LIKE 'f7000000-0001-%';
DELETE FROM sections WHERE id::text LIKE 'f7000000-0000-%';
DELETE FROM divisions WHERE id::text LIKE 'f7000000-0000-%';
DELETE FROM organizations WHERE id::text LIKE 'f7000000-0000-%';
