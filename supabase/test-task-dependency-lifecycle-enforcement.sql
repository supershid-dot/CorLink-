-- CorLink - T3F.2 authenticated lifecycle/RLS suite (30 scenarios)
-- Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

CREATE TEMP TABLE t3f2_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE t3f2_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT, UPDATE ON t3f2_results, t3f2_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('f5000000-0000-0000-0000-000000000001','T3F2 Org A','authority','T3F2A'),
 ('f5000000-0000-0000-0000-000000000002','T3F2 Org B','authority','T3F2B');
INSERT INTO divisions(id,name,org_id) VALUES
 ('f5000000-0000-0000-0000-000000000011','T3F2 Division A','f5000000-0000-0000-0000-000000000001');
INSERT INTO sections(id,name,code,org_id,division_id) VALUES
 ('f5000000-0000-0000-0000-000000000021','T3F2 Section A','T3F2SA','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000011');
INSERT INTO auth.users(id,email) VALUES
 ('f5000000-0001-0000-0000-000000000001','manager@t3f2.local'),
 ('f5000000-0001-0000-0000-000000000002','viewer@t3f2.local'),
 ('f5000000-0001-0000-0000-000000000003','assignee@t3f2.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','T3F2-1','Lifecycle Manager','manager@t3f2.local',true,false),
 ('f5000000-0001-0000-0000-000000000002','f5000000-0000-0000-0000-000000000001','T3F2-2','Lifecycle Viewer','viewer@t3f2.local',true,false),
 ('f5000000-0001-0000-0000-000000000003','f5000000-0000-0000-0000-000000000001','T3F2-3','Hidden Endpoint Assignee','assignee@t3f2.local',true,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('f5000000-0001-0000-0000-000000000001','section','f5000000-0000-0000-0000-000000000021','staff',true,true),
 ('f5000000-0001-0000-0000-000000000002','section','f5000000-0000-0000-0000-000000000021','staff',true,true),
 ('f5000000-0001-0000-0000-000000000003','section','f5000000-0000-0000-0000-000000000021','staff',true,true);

INSERT INTO tasks(id,task_number,title,status,priority,completed_at,completed_by,created_by,organization_id,owning_section_id,visibility) VALUES
 ('f5000000-1000-0000-0000-000000000001','T3F2-A','No prerequisites','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000002','T3F2-B','One unresolved','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000003','T3F2-C','Two unresolved','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000004','T3F2-D','Mixed prerequisites','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000005','T3F2-E','Resolved prerequisites','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000006','T3F2-F','Legacy blocked in progress','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000007','T3F2-G','Completable dependent','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000008','T3F2-H','Cancelled prerequisite dependent','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000009','T3F2-I','Removed dependency dependent','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000010','T3F2-J','Recreated dependency dependent','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000011','T3F2-K','Cancellable blocked','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000012','T3F2-L','No auto start','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000013','T3F2-M','No auto complete','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000014','T3F2-N','Unauthorized start','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000015','T3F2-O','Unauthorized complete','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000016','T3F2-Q','Direct rules unchanged','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000017','T3F2-X','Visible dependent','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000018','T3F2-SECRET','Confidential Prerequisite Alpha','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','private'),
 ('f5000000-1000-0000-0000-000000000019','T3F2-P1','Prerequisite One','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000020','T3F2-P2','Prerequisite Two','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000021','T3F2-PC1','Completed Prerequisite One','completed','normal',now(),'f5000000-0001-0000-0000-000000000001','f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000022','T3F2-PC2','Completed Prerequisite Two','completed','normal',now(),'f5000000-0001-0000-0000-000000000001','f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000023','T3F2-PX','Cancelled Prerequisite','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000024','T3F2-P3','Completing prerequisite','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-1000-0000-0000-000000000025','T3F2-P4','Completing prerequisite two','in_progress','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000021','organization'),
 ('f5000000-2000-0000-0000-000000000001','T3F2-CROSS','Cross Organization Task','open','normal',NULL,NULL,'f5000000-0001-0000-0000-000000000001','f5000000-0000-0000-0000-000000000002',NULL,'organization');

INSERT INTO task_assignments(task_id,user_id,assigned_by,is_active) VALUES
 ('f5000000-1000-0000-0000-000000000017','f5000000-0001-0000-0000-000000000003','f5000000-0001-0000-0000-000000000001',true);
INSERT INTO task_watchers(task_id,user_id) VALUES
 ('f5000000-1000-0000-0000-000000000007','f5000000-0001-0000-0000-000000000002');
INSERT INTO task_comments(task_id,author_id,body) VALUES
 ('f5000000-1000-0000-0000-000000000017','f5000000-0001-0000-0000-000000000003','Lifecycle regression marker');

-- Legacy fixtures for already-in-progress dependents; no application path can
-- add these now because T3F.1 rejects dependency creation after start.
INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by) VALUES
 ('f5000000-1000-0000-0000-000000000006','f5000000-1000-0000-0000-000000000019','f5000000-0000-0000-0000-000000000001','f5000000-0001-0000-0000-000000000001'),
 ('f5000000-1000-0000-0000-000000000007','f5000000-1000-0000-0000-000000000021','f5000000-0000-0000-0000-000000000001','f5000000-0001-0000-0000-000000000001'),
 ('f5000000-1000-0000-0000-000000000013','f5000000-1000-0000-0000-000000000025','f5000000-0000-0000-0000-000000000001','f5000000-0001-0000-0000-000000000001');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000001"}',false);

SELECT update_task('f5000000-1000-0000-0000-000000000001',p_status:='in_progress');
INSERT INTO t3f2_results VALUES(1,'open task without prerequisites starts');

INSERT INTO t3f2_ids SELECT 'b',(create_task_dependency('f5000000-1000-0000-0000-000000000002','f5000000-1000-0000-0000-000000000019')).id;
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000002',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' OR SQLERRM<>'Task cannot be started because one or more prerequisites are unresolved.' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(2,'one unresolved prerequisite blocks start');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000003','f5000000-1000-0000-0000-000000000019');
SELECT create_task_dependency('f5000000-1000-0000-0000-000000000003','f5000000-1000-0000-0000-000000000020');
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000003',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(3,'two unresolved prerequisites block start');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000004','f5000000-1000-0000-0000-000000000021');
SELECT create_task_dependency('f5000000-1000-0000-0000-000000000004','f5000000-1000-0000-0000-000000000019');
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000004',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(4,'mixed resolved and unresolved prerequisites block start');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000005','f5000000-1000-0000-0000-000000000021');
SELECT create_task_dependency('f5000000-1000-0000-0000-000000000005','f5000000-1000-0000-0000-000000000022');
SELECT update_task('f5000000-1000-0000-0000-000000000005',p_status:='in_progress');
INSERT INTO t3f2_results VALUES(5,'all completed prerequisites allow start');

DO $$ BEGIN BEGIN PERFORM complete_task('f5000000-1000-0000-0000-000000000006'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' OR SQLERRM<>'Task cannot be completed because one or more prerequisites are unresolved.' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(6,'in-progress blocked task cannot complete');

SELECT complete_task('f5000000-1000-0000-0000-000000000007','successful dependency completion');
INSERT INTO t3f2_results VALUES(7,'all completed prerequisites allow completion');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000008','f5000000-1000-0000-0000-000000000023');
SELECT cancel_task('f5000000-1000-0000-0000-000000000023','cancel after dependency creation');
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000008',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(8,'cancelled prerequisite remains unresolved');

INSERT INTO t3f2_ids SELECT 'i',(create_task_dependency('f5000000-1000-0000-0000-000000000009','f5000000-1000-0000-0000-000000000019')).id;
SELECT remove_task_dependency((SELECT id FROM t3f2_ids WHERE name='i'));
SELECT update_task('f5000000-1000-0000-0000-000000000009',p_status:='in_progress');
INSERT INTO t3f2_results VALUES(9,'removed dependency no longer blocks');

INSERT INTO t3f2_ids SELECT 'j1',(create_task_dependency('f5000000-1000-0000-0000-000000000010','f5000000-1000-0000-0000-000000000019')).id;
SELECT remove_task_dependency((SELECT id FROM t3f2_ids WHERE name='j1'));
INSERT INTO t3f2_ids SELECT 'j2',(create_task_dependency('f5000000-1000-0000-0000-000000000010','f5000000-1000-0000-0000-000000000019')).id;
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000010',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(10,'recreated dependency blocks again');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000011','f5000000-1000-0000-0000-000000000019');
SELECT cancel_task('f5000000-1000-0000-0000-000000000011','blocked cancellation remains allowed');
INSERT INTO t3f2_results VALUES(11,'blocked task cancellation remains allowed');

SELECT create_task_dependency('f5000000-1000-0000-0000-000000000012','f5000000-1000-0000-0000-000000000024');
SELECT complete_task('f5000000-1000-0000-0000-000000000024');
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f5000000-1000-0000-0000-000000000012')<>'open' THEN RAISE EXCEPTION 'dependent auto-started'; END IF; END $$;
INSERT INTO t3f2_results VALUES(12,'prerequisite completion does not auto-start dependent');

SELECT complete_task('f5000000-1000-0000-0000-000000000025');
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f5000000-1000-0000-0000-000000000013')<>'in_progress' THEN RAISE EXCEPTION 'dependent auto-completed'; END IF; END $$;
INSERT INTO t3f2_results VALUES(13,'prerequisite completion does not auto-complete dependent');

DO $$ BEGIN IF EXISTS(SELECT 1 FROM tasks WHERE id IN ('f5000000-1000-0000-0000-000000000002','f5000000-1000-0000-0000-000000000019') AND status<>'open') THEN RAISE EXCEPTION 'dependency add mutated status'; END IF; END $$;
INSERT INTO t3f2_results VALUES(14,'dependency creation mutates neither endpoint status');
DO $$ BEGIN IF (SELECT status FROM tasks WHERE id='f5000000-1000-0000-0000-000000000009')<>'in_progress' OR (SELECT status FROM tasks WHERE id='f5000000-1000-0000-0000-000000000019')<>'open' THEN RAISE EXCEPTION 'dependency removal mutated status'; END IF; END $$;
INSERT INTO t3f2_results VALUES(15,'dependency removal mutates neither endpoint status');

SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000014',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' OR SQLERRM<>'Not authorized to update this task' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(16,'existing authorization denies unauthorized start');
DO $$ BEGIN BEGIN PERFORM complete_task('f5000000-1000-0000-0000-000000000015'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' OR SQLERRM<>'Not authorized to complete this task' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(17,'existing authorization denies unauthorized completion');

SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000001"}',false);
SELECT create_task_dependency('f5000000-1000-0000-0000-000000000017','f5000000-1000-0000-0000-000000000018');
SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000003"}',false);
DO $$ DECLARE s RECORD; BEGIN SELECT * INTO s FROM get_task_dependency_lifecycle_state('f5000000-1000-0000-0000-000000000017'); IF s.active_prerequisite_count IS NOT NULL OR s.unresolved_prerequisite_count IS NOT NULL OR NOT s.is_blocked OR s.can_start OR s.can_complete THEN RAISE EXCEPTION 'hidden dependency state leaked or failed open: %',row_to_json(s); END IF; END $$;
INSERT INTO t3f2_results VALUES(18,'dependency lifecycle state does not broaden visibility');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM task_dependencies WHERE dependent_task_id='f5000000-1000-0000-0000-000000000017') THEN RAISE EXCEPTION 'hidden dependency row visible'; END IF; END $$;
INSERT INTO t3f2_results VALUES(19,'hidden prerequisite count and row cannot be inferred');
DO $$ DECLARE v_message TEXT; BEGIN BEGIN PERFORM update_task('f5000000-1000-0000-0000-000000000017',p_status:='in_progress'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN v_message:=SQLERRM; IF v_message='accepted' OR v_message<>'Task cannot be started because one or more prerequisites are unresolved.' OR v_message ~* 'Confidential|SECRET|Alpha|T3F2-' THEN RAISE EXCEPTION 'unsafe hidden error: %',v_message; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(20,'hidden prerequisite title and number absent from blocked error');

SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN BEGIN PERFORM create_task_dependency('f5000000-1000-0000-0000-000000000002','f5000000-2000-0000-0000-000000000001'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END; END $$;
INSERT INTO t3f2_results VALUES(21,'cross-organization dependency remains impossible');

SELECT complete_task('f5000000-1000-0000-0000-000000000016','unchanged direct completion');
INSERT INTO t3f2_results VALUES(22,'unblocked direct completion rules remain unchanged');

DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM audit_logs WHERE record_type='task' AND record_id='f5000000-1000-0000-0000-000000000001' AND action='edited') OR NOT EXISTS(SELECT 1 FROM audit_logs WHERE record_type='task' AND record_id='f5000000-1000-0000-0000-000000000007' AND action='completed') THEN RAISE EXCEPTION 'successful lifecycle audit missing'; END IF; END $$;
INSERT INTO t3f2_results VALUES(23,'successful start and complete retain Task audit');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM audit_logs WHERE record_type='task' AND record_id IN ('f5000000-1000-0000-0000-000000000002','f5000000-1000-0000-0000-000000000006') AND action IN ('edited','completed')) THEN RAISE EXCEPTION 'blocked success audit written'; END IF; END $$;
INSERT INTO t3f2_results VALUES(24,'failed blocked attempts write no success audit');
RESET ROLE;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM notifications WHERE record_id IN ('f5000000-1000-0000-0000-000000000002','f5000000-1000-0000-0000-000000000006')) OR NOT EXISTS(SELECT 1 FROM notifications WHERE type='task_completed' AND record_id='f5000000-1000-0000-0000-000000000007' AND user_id='f5000000-0001-0000-0000-000000000002') THEN RAISE EXCEPTION 'notification behavior changed'; END IF; END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f5000000-0001-0000-0000-000000000001"}',false);
INSERT INTO t3f2_results VALUES(25,'existing notifications unchanged and blocked attempts silent');

DO $$ DECLARE rid UUID; BEGIN rid:=create_task_relationship('f5000000-1000-0000-0000-000000000001','f5000000-1000-0000-0000-000000000016','related'); PERFORM remove_task_relationship(rid); END $$;
INSERT INTO t3f2_results VALUES(26,'informational Task Relationships unaffected');
DO $$ BEGIN IF to_regclass('public.task_links') IS NULL OR to_regprocedure('list_task_request_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_meeting_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_internal_collaboration_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_entry_links(uuid,integer,integer)') IS NULL OR to_regprocedure('list_task_prisoner_letter_links(uuid,integer,integer)') IS NULL THEN RAISE EXCEPTION 'module task_links regression'; END IF; END $$;
INSERT INTO t3f2_results VALUES(27,'all module task_links unaffected');
DO $$ BEGIN IF to_regclass('public.attachments') IS NULL OR NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task''%' FROM pg_constraint WHERE conname='attachments_record_type_check') THEN RAISE EXCEPTION 'Task attachment regression'; END IF; END $$;
INSERT INTO t3f2_results VALUES(28,'Task attachments unaffected');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM list_tasks('f5000000-0000-0000-0000-000000000001',NULL,NULL,FALSE,100) WHERE id='f5000000-1000-0000-0000-000000000001' AND status='in_progress') OR to_regprocedure('list_tasks(uuid,uuid,text,boolean,integer)') IS NULL THEN RAISE EXCEPTION 'Task List/dashboard data regression'; END IF; END $$;
INSERT INTO t3f2_results VALUES(29,'Task List and dashboard source data unaffected');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM task_comments WHERE task_id='f5000000-1000-0000-0000-000000000017') OR NOT EXISTS(SELECT 1 FROM task_assignments WHERE task_id='f5000000-1000-0000-0000-000000000017' AND is_active) OR NOT EXISTS(SELECT 1 FROM task_watchers WHERE task_id='f5000000-1000-0000-0000-000000000007') THEN RAISE EXCEPTION 'Task Detail child data regression'; END IF; END $$;
INSERT INTO t3f2_results VALUES(30,'comments assignments and watchers unaffected');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM t3f2_results)<>30 OR (SELECT min(scenario) FROM t3f2_results)<>1 OR (SELECT max(scenario) FROM t3f2_results)<>30 THEN RAISE EXCEPTION 'Expected 30 passing scenarios, got %',(SELECT count(*) FROM t3f2_results); END IF; RAISE NOTICE 'TASK DEPENDENCY LIFECYCLE: 30 PASSED, 0 FAILED'; END $$;

DELETE FROM notifications WHERE user_id::text LIKE 'f5000000-%' OR record_id::text LIKE 'f5000000-%';
DELETE FROM audit_logs WHERE user_id::text LIKE 'f5000000-%' OR record_id::text LIKE 'f5000000-%';
DELETE FROM task_relationships WHERE source_task_id::text LIKE 'f5000000-%' OR target_task_id::text LIKE 'f5000000-%';
DELETE FROM task_dependency_waivers WHERE dependency_id IN (SELECT id FROM task_dependencies WHERE dependent_task_id::text LIKE 'f5000000-%');
DELETE FROM task_dependencies WHERE dependent_task_id::text LIKE 'f5000000-%' OR prerequisite_task_id::text LIKE 'f5000000-%';
DELETE FROM task_comments WHERE task_id::text LIKE 'f5000000-%';
DELETE FROM task_watchers WHERE task_id::text LIKE 'f5000000-%';
DELETE FROM task_assignments WHERE task_id::text LIKE 'f5000000-%';
DELETE FROM tasks WHERE id::text LIKE 'f5000000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE 'f5000000-%';
DELETE FROM users WHERE id::text LIKE 'f5000000-%';
DELETE FROM auth.users WHERE id::text LIKE 'f5000000-%';
DELETE FROM sections WHERE id::text LIKE 'f5000000-%';
DELETE FROM divisions WHERE id::text LIKE 'f5000000-%';
DELETE FROM organizations WHERE id::text LIKE 'f5000000-%';
