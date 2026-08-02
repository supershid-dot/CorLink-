-- CAP-002 Phase 2 runtime authorization/RLS suite (12 scenarios)
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf_runtime_rls_results (scenario INTEGER PRIMARY KEY,name TEXT NOT NULL);
CREATE TEMP TABLE wf_runtime_rls_ids (name TEXT PRIMARY KEY,id UUID NOT NULL);
GRANT SELECT,INSERT ON wf_runtime_rls_results,wf_runtime_rls_ids TO authenticated;
GRANT SELECT ON wf_runtime_rls_ids TO anon;

INSERT INTO organizations(id,name,type,code) VALUES
 ('62600000-0000-0000-0000-000000000001','Runtime RLS A','authority','WRL-A'),
 ('62600000-0000-0000-0000-000000000002','Runtime RLS B','authority','WRL-B');
INSERT INTO auth.users(id,email) VALUES
 ('62600000-0001-0000-0000-000000000001','owner@wrl.local'),
 ('62600000-0001-0000-0000-000000000002','manager@wrl.local'),
 ('62600000-0001-0000-0000-000000000003','viewer@wrl.local'),
 ('62600000-0001-0000-0000-000000000004','outsider@wrl.local'),
 ('62600000-0001-0000-0000-000000000005','cross@wrl.local'),
 ('62600000-0001-0000-0000-000000000006','super@wrl.local'),
 ('62600000-0001-0000-0000-000000000007','inactive@wrl.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62600000-0001-0000-0000-000000000001','62600000-0000-0000-0000-000000000001','WRL-1','Owner','owner@wrl.local',true,false),
 ('62600000-0001-0000-0000-000000000002','62600000-0000-0000-0000-000000000001','WRL-2','Manager','manager@wrl.local',true,false),
 ('62600000-0001-0000-0000-000000000003','62600000-0000-0000-0000-000000000001','WRL-3','Viewer','viewer@wrl.local',true,false),
 ('62600000-0001-0000-0000-000000000004','62600000-0000-0000-0000-000000000001','WRL-4','Outsider','outsider@wrl.local',true,false),
 ('62600000-0001-0000-0000-000000000005','62600000-0000-0000-0000-000000000002','WRL-5','Cross Org','cross@wrl.local',true,false),
 ('62600000-0001-0000-0000-000000000006','62600000-0000-0000-0000-000000000002','WRL-6','Super Admin','super@wrl.local',true,true),
 ('62600000-0001-0000-0000-000000000007','62600000-0000-0000-0000-000000000001','WRL-7','Inactive Owner','inactive@wrl.local',false,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('62600000-0001-0000-0000-000000000001','organization','62600000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('62600000-0001-0000-0000-000000000002','organization','62600000-0000-0000-0000-000000000001','staff',true,true),
 ('62600000-0001-0000-0000-000000000003','organization','62600000-0000-0000-0000-000000000001','staff',true,true),
 ('62600000-0001-0000-0000-000000000004','organization','62600000-0000-0000-0000-000000000001','staff',true,true),
 ('62600000-0001-0000-0000-000000000005','organization','62600000-0000-0000-0000-000000000002','staff',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition('62600000-0000-0000-0000-000000000001','runtime_rls_flow','Runtime RLS','opaque_record','{"nodes":[],"edges":[]}','62600000-1000-0000-0000-000000000001'))
INSERT INTO wf_runtime_rls_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf_runtime_rls_ids WHERE name='version'),0,'62600000-1000-0000-0000-000000000002');
INSERT INTO wf_runtime_rls_ids VALUES
 ('shared',create_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='version'),'opaque_record','62600000-2000-0000-0000-000000000001','62600000-0000-0000-0000-000000000001','62600000-3000-0000-0000-000000000001',NULL)),
 ('inactive',create_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='version'),'opaque_record','62600000-2000-0000-0000-000000000002','62600000-0000-0000-0000-000000000001','62600000-3000-0000-0000-000000000002',NULL));
RESET ROLE;

INSERT INTO workflow_participants(instance_id,user_id,participant_role,authority_source,created_by) VALUES
 ((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),'62600000-0001-0000-0000-000000000002','manager','test','62600000-0001-0000-0000-000000000001'),
 ((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),'62600000-0001-0000-0000-000000000003','viewer','test','62600000-0001-0000-0000-000000000001'),
 ((SELECT id FROM wf_runtime_rls_ids WHERE name='inactive'),'62600000-0001-0000-0000-000000000007','owner','test','62600000-0001-0000-0000-000000000001');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000001"}',true);
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),0,'62600000-4000-0000-0000-000000000001');
INSERT INTO wf_runtime_rls_results VALUES(1,'owner may start managed instance');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_rls_ids WHERE name='shared'))<>2 THEN RAISE EXCEPTION 'owner event visibility'; END IF; END $$;
INSERT INTO wf_runtime_rls_results VALUES(2,'owner sees immutable runtime event');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000002"}',true);
SELECT * FROM suspend_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),1,'62600000-4000-0000-0000-000000000002','manager_pause');
INSERT INTO wf_runtime_rls_results VALUES(3,'manager participant may suspend');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000003"}',true);
DO $$ BEGIN BEGIN PERFORM resume_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),2,'62600000-4000-0000-0000-000000000003','viewer_resume'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO wf_runtime_rls_results VALUES(4,'viewer participant cannot transition');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_rls_ids WHERE name='shared'))<>3 THEN RAISE EXCEPTION 'viewer event visibility'; END IF; END $$;
INSERT INTO wf_runtime_rls_results VALUES(5,'viewer retains read-only event visibility');
DO $$ BEGIN BEGIN UPDATE workflow_instances SET status='active' WHERE id=(SELECT id FROM wf_runtime_rls_ids WHERE name='shared'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO wf_runtime_rls_results VALUES(6,'authenticated direct runtime update is denied');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000004"}',true);
DO $$ BEGIN BEGIN PERFORM resume_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),2,'62600000-4000-0000-0000-000000000004','outsider_resume'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO wf_runtime_rls_results VALUES(7,'same-org nonparticipant cannot transition');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM workflow_instances WHERE id=(SELECT id FROM wf_runtime_rls_ids WHERE name='shared')) THEN RAISE EXCEPTION 'same-org RLS leak'; END IF; END $$;
INSERT INTO wf_runtime_rls_results VALUES(8,'same-org nonparticipant cannot read instance');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000005"}',true);
DO $$ BEGIN BEGIN PERFORM resume_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),2,'62600000-4000-0000-0000-000000000005','cross_resume'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO wf_runtime_rls_results VALUES(9,'cross-org nonparticipant cannot transition');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000007"}',true);
DO $$ BEGIN BEGIN PERFORM start_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='inactive'),0,'62600000-4000-0000-0000-000000000006'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
INSERT INTO wf_runtime_rls_results VALUES(10,'inactive participant fails closed');

SELECT set_config('request.jwt.claims','{"sub":"62600000-0001-0000-0000-000000000006"}',true);
SELECT * FROM resume_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='shared'),2,'62600000-4000-0000-0000-000000000007','superadmin_recovery');
INSERT INTO wf_runtime_rls_results VALUES(11,'super administrator emergency management remains explicit');

RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN BEGIN PERFORM start_workflow_instance((SELECT id FROM wf_runtime_rls_ids WHERE name='inactive'),0,'62600000-4000-0000-0000-000000000008'); RAISE EXCEPTION 'executable'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
RESET ROLE;
INSERT INTO wf_runtime_rls_results VALUES(12,'anonymous role cannot execute runtime RPCs');

DO $$ BEGIN IF (SELECT count(*) FROM wf_runtime_rls_results)<>12 THEN RAISE EXCEPTION 'Expected 12 RLS scenarios'; END IF; END $$;
SELECT 'Workflow runtime RLS tests PASSED: 12/12' AS result;
ROLLBACK;
