-- CorLink — T3F.1 authenticated behavioral/RLS suite (31 scenarios)
-- Disposable local PostgreSQL only. Creates fixed f1... fixtures and removes them.
\set ON_ERROR_STOP on

CREATE TEMP TABLE t3f1_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE t3f1_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT, UPDATE ON t3f1_results, t3f1_ids TO authenticated;

INSERT INTO organizations (id,name,type,code) VALUES
 ('f1000000-0000-0000-0000-000000000001','T3F1 Org A','authority','T3F1A'),
 ('f1000000-0000-0000-0000-000000000002','T3F1 Org B','authority','T3F1B');
INSERT INTO divisions (id,name,org_id) VALUES
 ('f1000000-0000-0000-0000-000000000011','T3F1 Division A','f1000000-0000-0000-0000-000000000001'),
 ('f1000000-0000-0000-0000-000000000012','T3F1 Division B','f1000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('f1000000-0000-0000-0000-000000000021','T3F1 Section A','T3F1SA','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000011'),
 ('f1000000-0000-0000-0000-000000000022','T3F1 Section B','T3F1SB','f1000000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-000000000012');
INSERT INTO auth.users (id,email) VALUES
 ('f1000000-0001-0000-0000-000000000001','manager@t3f1.local'),
 ('f1000000-0001-0000-0000-000000000002','dependent@t3f1.local'),
 ('f1000000-0001-0000-0000-000000000003','prerequisite@t3f1.local'),
 ('f1000000-0001-0000-0000-000000000004','viewer@t3f1.local'),
 ('f1000000-0001-0000-0000-000000000005','super@t3f1.local'),
 ('f1000000-0001-0000-0000-000000000006','one-side@t3f1.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','T3F1-1','Both Manager','manager@t3f1.local',true,false),
 ('f1000000-0001-0000-0000-000000000002','f1000000-0000-0000-0000-000000000001','T3F1-2','Dependent Manager','dependent@t3f1.local',true,false),
 ('f1000000-0001-0000-0000-000000000003','f1000000-0000-0000-0000-000000000001','T3F1-3','Prerequisite Manager','prerequisite@t3f1.local',true,false),
 ('f1000000-0001-0000-0000-000000000004','f1000000-0000-0000-0000-000000000001','T3F1-4','Both Viewer','viewer@t3f1.local',true,false),
 ('f1000000-0001-0000-0000-000000000005','f1000000-0000-0000-0000-000000000001','T3F1-5','Cross Org Super','super@t3f1.local',true,true),
 ('f1000000-0001-0000-0000-000000000006','f1000000-0000-0000-0000-000000000001','T3F1-6','One Side Viewer','one-side@t3f1.local',true,false);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('f1000000-0001-0000-0000-000000000001','section','f1000000-0000-0000-0000-000000000021','staff',true,true),
 ('f1000000-0001-0000-0000-000000000002','section','f1000000-0000-0000-0000-000000000021','staff',true,true),
 ('f1000000-0001-0000-0000-000000000003','section','f1000000-0000-0000-0000-000000000021','staff',true,true),
 ('f1000000-0001-0000-0000-000000000004','section','f1000000-0000-0000-0000-000000000021','staff',true,true),
 ('f1000000-0001-0000-0000-000000000006','section','f1000000-0000-0000-0000-000000000021','staff',true,true);

INSERT INTO tasks (id,task_number,title,status,priority,completed_at,completed_by,created_by,organization_id,owning_section_id,visibility) VALUES
 ('f1000000-1000-0000-0000-000000000001','T3F1-A','A','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000002','T3F1-B','B','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000003','T3F1-C','C','completed','normal',now(),'f1000000-0001-0000-0000-000000000001','f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000004','T3F1-D','D','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000005','T3F1-E','E','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000006','T3F1-F','F','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000007','T3F1-G','G','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000008','T3F1-H','H','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000009','T3F1-I','I','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000010','T3F1-J','J','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000011','T3F1-K','K','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000012','T3F1-L','L','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','private'),
 ('f1000000-1000-0000-0000-000000000013','T3F1-S','Source only','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000002','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','organization'),
 ('f1000000-1000-0000-0000-000000000014','T3F1-T','Target only','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000003','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000021','organization'),
 ('f1000000-1000-0000-0000-000000000015','T3F1-X','Cross org','open','normal',NULL,NULL,'f1000000-0001-0000-0000-000000000005','f1000000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-000000000022','private');
INSERT INTO task_assignments (task_id,user_id,assigned_by,is_active) VALUES
 ('f1000000-1000-0000-0000-000000000001','f1000000-0001-0000-0000-000000000006','f1000000-0001-0000-0000-000000000001',true),
 ('f1000000-1000-0000-0000-000000000013','f1000000-0001-0000-0000-000000000001','f1000000-0001-0000-0000-000000000002',true),
 ('f1000000-1000-0000-0000-000000000014','f1000000-0001-0000-0000-000000000001','f1000000-0001-0000-0000-000000000003',true);

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);

INSERT INTO t3f1_ids SELECT 'ab',(create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000002')).id;
INSERT INTO t3f1_results VALUES(1,'authorized create A depends on B');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM list_task_dependencies('f1000000-1000-0000-0000-000000000001',50,0) WHERE direction='depends_on' AND related_task_id='f1000000-1000-0000-0000-000000000002') THEN RAISE EXCEPTION 'depends_on listing missing'; END IF; END $$;
INSERT INTO t3f1_results VALUES(2,'dependent listing derives depends_on');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM list_task_dependencies('f1000000-1000-0000-0000-000000000002',50,0) WHERE direction='blocks' AND related_task_id='f1000000-1000-0000-0000-000000000001') THEN RAISE EXCEPTION 'blocks listing missing'; END IF; END $$;
INSERT INTO t3f1_results VALUES(3,'prerequisite listing derives blocks');

DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000001'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(4,'self dependency rejected');
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000002'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(5,'duplicate active pair rejected');
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000002','f1000000-1000-0000-0000-000000000001'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(6,'reverse direct cycle rejected');

SELECT create_task_dependency('f1000000-1000-0000-0000-000000000004','f1000000-1000-0000-0000-000000000005');
SELECT create_task_dependency('f1000000-1000-0000-0000-000000000005','f1000000-1000-0000-0000-000000000006');
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000006','f1000000-1000-0000-0000-000000000004'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(7,'three-node cycle rejected');
SELECT create_task_dependency('f1000000-1000-0000-0000-000000000007','f1000000-1000-0000-0000-000000000008');
SELECT create_task_dependency('f1000000-1000-0000-0000-000000000008','f1000000-1000-0000-0000-000000000009');
SELECT create_task_dependency('f1000000-1000-0000-0000-000000000009','f1000000-1000-0000-0000-000000000010');
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000010','f1000000-1000-0000-0000-000000000007'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(8,'long indirect cycle rejected');

INSERT INTO t3f1_ids SELECT 'ac',(create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000003')).id;
DO $$ BEGIN IF (SELECT count(*) FROM task_dependencies WHERE dependent_task_id='f1000000-1000-0000-0000-000000000001' AND removed_at IS NULL)<>2 THEN RAISE EXCEPTION 'multiple prerequisites missing'; END IF; END $$;
INSERT INTO t3f1_results VALUES(9,'multiple prerequisites stored independently');
RESET ROLE;
DO $$ DECLARE s RECORD; BEGIN SELECT * INTO s FROM get_task_dependency_state('f1000000-1000-0000-0000-000000000001'); IF s.active_prerequisite_count<>2 OR s.unresolved_prerequisite_count<>1 OR NOT s.is_blocked THEN RAISE EXCEPTION 'state mismatch: %',row_to_json(s); END IF; END $$;
INSERT INTO t3f1_results VALUES(10,'derived blocked state counts unresolved prerequisites');
DO $$ DECLARE s RECORD; BEGIN SELECT * INTO s FROM get_task_dependency_state('f1000000-1000-0000-0000-000000000001'); IF s.active_prerequisite_count-s.unresolved_prerequisite_count<>1 THEN RAISE EXCEPTION 'completed prerequisite unresolved'; END IF; END $$;
INSERT INTO t3f1_results VALUES(11,'completed prerequisite resolves in derived state');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);
SELECT create_task_dependency('f1000000-1000-0000-0000-000000000011','f1000000-1000-0000-0000-000000000012');
RESET ROLE;
UPDATE tasks SET status='cancelled' WHERE id='f1000000-1000-0000-0000-000000000012';
DO $$ DECLARE s RECORD; BEGIN SELECT * INTO s FROM get_task_dependency_state('f1000000-1000-0000-0000-000000000011'); IF s.unresolved_prerequisite_count<>1 OR NOT s.is_blocked THEN RAISE EXCEPTION 'cancelled prerequisite resolved'; END IF; END $$;
INSERT INTO t3f1_results VALUES(12,'cancelled prerequisite remains unresolved');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);
INSERT INTO t3f1_ids SELECT 'st',(create_task_dependency('f1000000-1000-0000-0000-000000000013','f1000000-1000-0000-0000-000000000014')).id;
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM search_tasks_for_dependency('f1000000-1000-0000-0000-000000000013','T3F1-T',20))
     OR EXISTS(SELECT 1 FROM search_tasks_for_dependency('f1000000-1000-0000-0000-000000000013','T3F1-X',20))
     OR NOT EXISTS(SELECT 1 FROM search_tasks_for_dependency('f1000000-1000-0000-0000-000000000013','T3F1-A',20) WHERE id='f1000000-1000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'bounded dependency picker filtering failed';
  END IF;
END $$;
INSERT INTO t3f1_results VALUES(13,'same-org manager of both can create');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000013','f1000000-1000-0000-0000-000000000014'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(14,'dependent-only manager denied');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000003"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000013','f1000000-1000-0000-0000-000000000014'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(15,'prerequisite-only manager denied');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000004"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000013','f1000000-1000-0000-0000-000000000014'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(16,'view-only actor denied');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000005"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000015'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(17,'cross-organization dependency rejected');

SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000006"}',false);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM list_task_dependencies('f1000000-1000-0000-0000-000000000001',50,0))
     OR EXISTS(SELECT 1 FROM task_dependencies WHERE dependent_task_id='f1000000-1000-0000-0000-000000000001')
     OR EXISTS(
       SELECT 1 FROM audit_logs al
       JOIN task_dependencies td ON td.id=al.record_id
       WHERE al.record_type='task_dependency'
         AND td.dependent_task_id='f1000000-1000-0000-0000-000000000001'
     ) THEN
    RAISE EXCEPTION 'one-side visibility leaked dependency';
  END IF;
END $$;
INSERT INTO t3f1_results VALUES(18,'one-endpoint viewer sees no dependency or audit row');
DO $$ BEGIN IF has_function_privilege('authenticated','get_task_dependency_state(uuid)','EXECUTE')
  OR EXISTS(SELECT 1 FROM list_task_dependencies('f1000000-1000-0000-0000-000000000001',1,0))
  OR EXISTS(SELECT 1 FROM search_tasks_for_dependency('f1000000-1000-0000-0000-000000000001','T3F1-B',20))
  THEN RAISE EXCEPTION 'hidden count inferable'; END IF; END $$;
INSERT INTO t3f1_results VALUES(19,'hidden dependency count cannot be inferred');

DO $$ BEGIN BEGIN INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by) VALUES('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000004','f1000000-0000-0000-0000-000000000001',auth.uid()); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO t3f1_results VALUES(20,'direct insert denied');
DO $$ BEGIN BEGIN UPDATE task_dependencies SET removed_at=now(),removed_by=auth.uid(); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO t3f1_results VALUES(21,'direct update denied');
DO $$ BEGIN BEGIN DELETE FROM task_dependencies; RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO t3f1_results VALUES(22,'direct delete denied');

SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);
SELECT remove_task_dependency((SELECT id FROM t3f1_ids WHERE name='ab'));
DO $$ BEGIN IF (SELECT removed_at IS NULL FROM task_dependencies WHERE id=(SELECT id FROM t3f1_ids WHERE name='ab')) THEN RAISE EXCEPTION 'not soft removed'; END IF; END $$;
INSERT INTO t3f1_results VALUES(23,'authorized removal soft-removes');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM remove_task_dependency((SELECT id FROM t3f1_ids WHERE name='st')); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f1_results VALUES(24,'one-endpoint manager cannot remove');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM tasks WHERE id IN ('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000002') AND status<>'open') THEN RAISE EXCEPTION 'status changed'; END IF; END $$;
INSERT INTO t3f1_results VALUES(25,'removal preserves both Task statuses');
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);
INSERT INTO t3f1_ids SELECT 'ab2',(create_task_dependency('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000002')).id;
INSERT INTO t3f1_results VALUES(26,'removed dependency recreates safely');
RESET ROLE;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM audit_logs WHERE record_type='task_dependency' AND (notes !~ '^dependent=[0-9a-f-]{36};prerequisite=[0-9a-f-]{36}$' OR notes ~ 'T3F1|Source|Target|Cross')) OR (SELECT count(*) FROM audit_logs WHERE record_type='task_dependency')<3 THEN RAISE EXCEPTION 'unsafe or missing dependency audit'; END IF; END $$;
INSERT INTO t3f1_results VALUES(27,'audit rows created with minimal identifiers');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f1000000-0001-0000-0000-000000000001"}',false);
DO $$ DECLARE rid UUID; BEGIN rid:=create_task_relationship('f1000000-1000-0000-0000-000000000001','f1000000-1000-0000-0000-000000000003','related'); PERFORM remove_task_relationship(rid); END $$;
INSERT INTO t3f1_results VALUES(28,'informational Task Relationships remain valid');
DO $$ BEGIN IF to_regclass('public.task_links') IS NULL OR to_regprocedure('list_task_request_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_meeting_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_internal_collaboration_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_entry_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_prisoner_letter_links(uuid,integer,integer)') IS NULL THEN RAISE EXCEPTION 'task_links regression'; END IF; END $$;
INSERT INTO t3f1_results VALUES(29,'all module task_links remain valid');
DO $$ BEGIN IF to_regclass('public.attachments') IS NULL OR NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task''%' FROM pg_constraint WHERE conname='attachments_record_type_check') THEN RAISE EXCEPTION 'attachments regression'; END IF; END $$;
INSERT INTO t3f1_results VALUES(30,'Task attachments remain valid');
DO $$ BEGIN IF to_regclass('public.task_comments') IS NULL OR to_regclass('public.task_assignments') IS NULL OR to_regclass('public.task_watchers') IS NULL OR to_regprocedure('update_task(uuid,text,text,text,text,date,date,uuid,text)') IS NULL OR to_regprocedure('list_tasks(uuid,uuid,text,boolean,integer)') IS NULL OR EXISTS(SELECT 1 FROM notifications WHERE type LIKE 'task_dependency%') THEN RAISE EXCEPTION 'foundation regression'; END IF; END $$;
INSERT INTO t3f1_results VALUES(31,'comments assignments watchers editing dashboard inputs unaffected');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM t3f1_results)<>31 OR (SELECT min(scenario) FROM t3f1_results)<>1 OR (SELECT max(scenario) FROM t3f1_results)<>31 THEN RAISE EXCEPTION 'Expected 31 passing scenarios, got %',(SELECT count(*) FROM t3f1_results); END IF; RAISE NOTICE 'TASK DEPENDENCIES: 31 PASSED, 0 FAILED'; END $$;

DELETE FROM audit_logs WHERE user_id::text LIKE 'f1000000-0001-%';
DELETE FROM task_relationships WHERE source_task_id::text LIKE 'f1000000-1000-%' OR target_task_id::text LIKE 'f1000000-1000-%';
DELETE FROM task_dependency_waivers WHERE dependency_id IN (SELECT id FROM task_dependencies WHERE dependent_task_id::text LIKE 'f1000000-1000-%');
DELETE FROM task_dependencies WHERE dependent_task_id::text LIKE 'f1000000-1000-%' OR prerequisite_task_id::text LIKE 'f1000000-1000-%';
DELETE FROM task_assignments WHERE task_id::text LIKE 'f1000000-1000-%';
DELETE FROM tasks WHERE id::text LIKE 'f1000000-1000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE 'f1000000-0001-%';
DELETE FROM users WHERE id::text LIKE 'f1000000-0001-%';
DELETE FROM auth.users WHERE id::text LIKE 'f1000000-0001-%';
DELETE FROM sections WHERE id::text LIKE 'f1000000-0000-%';
DELETE FROM divisions WHERE id::text LIKE 'f1000000-0000-%';
DELETE FROM organizations WHERE id::text LIKE 'f1000000-0000-%';
