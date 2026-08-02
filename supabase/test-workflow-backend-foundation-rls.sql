-- CAP-002 Phase 1 RLS suite (12 scenarios)
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf_rls_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf_rls_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf_rls_results, wf_rls_ids TO authenticated;
GRANT SELECT ON wf_rls_ids TO anon;

INSERT INTO organizations(id,name,type,code) VALUES
 ('62100000-0000-0000-0000-000000000001','Workflow RLS A','authority','WFR-A'),
 ('62100000-0000-0000-0000-000000000002','Workflow RLS B','authority','WFR-B');
INSERT INTO auth.users(id,email) VALUES
 ('62100000-0001-0000-0000-000000000001','owner@wfr.local'),
 ('62100000-0001-0000-0000-000000000002','viewer@wfr.local'),
 ('62100000-0001-0000-0000-000000000003','outsider@wfr.local'),
 ('62100000-0001-0000-0000-000000000004','other@wfr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('62100000-0001-0000-0000-000000000001','62100000-0000-0000-0000-000000000001','WFR-1','Owner','owner@wfr.local',true),
 ('62100000-0001-0000-0000-000000000002','62100000-0000-0000-0000-000000000001','WFR-2','Viewer','viewer@wfr.local',true),
 ('62100000-0001-0000-0000-000000000003','62100000-0000-0000-0000-000000000001','WFR-3','Outsider','outsider@wfr.local',true),
 ('62100000-0001-0000-0000-000000000004','62100000-0000-0000-0000-000000000002','WFR-4','Other','other@wfr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('62100000-0001-0000-0000-000000000001','organization','62100000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('62100000-0001-0000-0000-000000000002','organization','62100000-0000-0000-0000-000000000001','staff',true,true),
 ('62100000-0001-0000-0000-000000000003','organization','62100000-0000-0000-0000-000000000001','staff',true,true),
 ('62100000-0001-0000-0000-000000000004','organization','62100000-0000-0000-0000-000000000002','staff',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62100000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition('62100000-0000-0000-0000-000000000001','rls_flow','RLS Flow','opaque_record','{"nodes":[],"edges":[]}','62100000-1000-0000-0000-000000000001'))
INSERT INTO wf_rls_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf_rls_ids WHERE name='version'),0,'62100000-1000-0000-0000-000000000002');
INSERT INTO wf_rls_ids SELECT 'instance',create_workflow_instance((SELECT id FROM wf_rls_ids WHERE name='version'),'opaque_record','62100000-2000-0000-0000-000000000001','62100000-0000-0000-0000-000000000001','62100000-1000-0000-0000-000000000003',NULL);
RESET ROLE;

INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key) VALUES ('62100000-3000-0000-0000-000000000001',(SELECT id FROM wf_rls_ids WHERE name='instance'),'seed');
INSERT INTO workflow_tokens(id,instance_id,step_id,token_key) VALUES ('62100000-3000-0000-0000-000000000002',(SELECT id FROM wf_rls_ids WHERE name='instance'),'62100000-3000-0000-0000-000000000001','seed_token');
INSERT INTO workflow_work_items(id,instance_id,step_id,token_id,work_item_type,organization_id,assigned_to)
 VALUES ('62100000-3000-0000-0000-000000000003',(SELECT id FROM wf_rls_ids WHERE name='instance'),'62100000-3000-0000-0000-000000000001','62100000-3000-0000-0000-000000000002','activity','62100000-0000-0000-0000-000000000001','62100000-0001-0000-0000-000000000002');
INSERT INTO workflow_participants(instance_id,user_id,participant_role,authority_source,created_by) VALUES
 ((SELECT id FROM wf_rls_ids WHERE name='instance'),'62100000-0001-0000-0000-000000000002','viewer','test','62100000-0001-0000-0000-000000000001');
INSERT INTO workflow_variables(instance_id,variable_name,value_type,variable_value,classification,created_by,updated_by)
 VALUES ((SELECT id FROM wf_rls_ids WHERE name='instance'),'secret','string','"restricted"','restricted','62100000-0001-0000-0000-000000000001','62100000-0001-0000-0000-000000000001');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62100000-0001-0000-0000-000000000001"}',true);
DO $$ BEGIN IF (SELECT count(*) FROM workflow_definitions)<>1 OR (SELECT count(*) FROM workflow_definition_versions)<>1 THEN RAISE EXCEPTION 'manager definition visibility'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(1,'definition manager sees family and version');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_instances)<>1 OR (SELECT count(*) FROM workflow_instance_steps)<>1 OR (SELECT count(*) FROM workflow_tokens)<>1 THEN RAISE EXCEPTION 'owner aggregate visibility'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(2,'owner sees instance step and token');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_variables)<>1 THEN RAISE EXCEPTION 'owner variable visibility'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(3,'owner manager sees restricted variables');

SELECT set_config('request.jwt.claims','{"sub":"62100000-0001-0000-0000-000000000002"}',true);
DO $$ BEGIN IF (SELECT count(*) FROM workflow_instances)<>1 OR (SELECT count(*) FROM workflow_work_items)<>1 THEN RAISE EXCEPTION 'viewer aggregate'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(4,'explicit viewer sees instance and work item');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_definitions)<>0 OR (SELECT count(*) FROM workflow_definition_versions)<>0 THEN RAISE EXCEPTION 'definition leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(5,'nonmanager participant cannot enumerate definitions');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_variables)<>0 THEN RAISE EXCEPTION 'variable leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(6,'viewer cannot read restricted variables');
DO $$ BEGIN IF (SELECT count(*) FROM workflow_participants)<>2 OR (SELECT count(*) FROM workflow_events)<>1 THEN RAISE EXCEPTION 'history visibility'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(7,'participant sees participant and event history');

SELECT set_config('request.jwt.claims','{"sub":"62100000-0001-0000-0000-000000000003"}',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM workflow_instances) OR EXISTS(SELECT 1 FROM workflow_work_items) OR EXISTS(SELECT 1 FROM workflow_events) THEN RAISE EXCEPTION 'same-org leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(8,'same-org nonparticipant sees no aggregate data');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM workflow_definitions) THEN RAISE EXCEPTION 'staff definition leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(9,'same-org staff cannot enumerate definition plane');

SELECT set_config('request.jwt.claims','{"sub":"62100000-0001-0000-0000-000000000004"}',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM workflow_instances) OR EXISTS(SELECT 1 FROM workflow_participants) THEN RAISE EXCEPTION 'cross-org leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(10,'cross-org nonparticipant sees no aggregate data');

SELECT set_config('request.jwt.claims','',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM workflow_instances) OR EXISTS(SELECT 1 FROM workflow_definitions) THEN RAISE EXCEPTION 'anonymous claim leak'; END IF; END $$;
INSERT INTO wf_rls_results VALUES(11,'missing identity fails closed');
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN BEGIN PERFORM get_workflow_instance((SELECT id FROM wf_rls_ids WHERE name='instance')); RAISE EXCEPTION 'rpc executable'; EXCEPTION WHEN insufficient_privilege THEN NULL; END; END $$;
RESET ROLE;
INSERT INTO wf_rls_results VALUES(12,'anonymous role has no RPC execution contract');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM wf_rls_results)<>12 THEN RAISE EXCEPTION 'Expected 12 scenarios'; END IF; END $$;
SELECT 'Workflow backend RLS tests PASSED: 12/12' AS result;
ROLLBACK;
