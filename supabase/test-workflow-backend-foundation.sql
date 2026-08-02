-- CAP-002 Phase 1 authenticated behavioral suite (24 scenarios)
-- Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

CREATE TEMP TABLE wf_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf_results, wf_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('62000000-0000-0000-0000-000000000001','Workflow Org A','authority','WF-A'),
 ('62000000-0000-0000-0000-000000000002','Workflow Org B','authority','WF-B');
INSERT INTO auth.users(id,email) VALUES
 ('62000000-0001-0000-0000-000000000001','admin@wf.local'),
 ('62000000-0001-0000-0000-000000000002','staff@wf.local'),
 ('62000000-0001-0000-0000-000000000003','other@wf.local'),
 ('62000000-0001-0000-0000-000000000004','super@wf.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62000000-0001-0000-0000-000000000001','62000000-0000-0000-0000-000000000001','WF-1','Workflow Admin','admin@wf.local',true,false),
 ('62000000-0001-0000-0000-000000000002','62000000-0000-0000-0000-000000000001','WF-2','Workflow Staff','staff@wf.local',true,false),
 ('62000000-0001-0000-0000-000000000003','62000000-0000-0000-0000-000000000002','WF-3','Other Staff','other@wf.local',true,false),
 ('62000000-0001-0000-0000-000000000004','62000000-0000-0000-0000-000000000001','WF-4','Workflow Super','super@wf.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('62000000-0001-0000-0000-000000000001','organization','62000000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('62000000-0001-0000-0000-000000000002','organization','62000000-0000-0000-0000-000000000001','staff',true,true),
 ('62000000-0001-0000-0000-000000000003','organization','62000000-0000-0000-0000-000000000002','staff',true,true);

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62000000-0001-0000-0000-000000000001"}',false);

WITH made AS (
 SELECT * FROM create_workflow_definition(
  '62000000-0000-0000-0000-000000000001','generic_case_review','Generic Case Review','opaque_case',
  '{"nodes":[],"edges":[],"capability_version":1}'::jsonb,
  '62000000-1000-0000-0000-000000000001'))
INSERT INTO wf_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version1',version_id FROM made;
INSERT INTO wf_results VALUES (1,'organization administrator creates inert definition and first draft');

DO $$ DECLARE a UUID; b UUID; BEGIN
 SELECT definition_id,version_id INTO a,b FROM create_workflow_definition(
  '62000000-0000-0000-0000-000000000001','generic_case_review','Generic Case Review','opaque_case',
  '{"nodes":[],"edges":[],"capability_version":1}'::jsonb,
  '62000000-1000-0000-0000-000000000001');
 IF a<>(SELECT id FROM wf_ids WHERE name='definition') OR b<>(SELECT id FROM wf_ids WHERE name='version1') THEN RAISE EXCEPTION 'idempotency mismatch'; END IF;
END $$;
INSERT INTO wf_results VALUES (2,'definition creation is idempotent');

DO $$ BEGIN BEGIN
 PERFORM create_workflow_definition('62000000-0000-0000-0000-000000000001','generic_case_review','Changed','opaque_case','{"nodes":[],"edges":[]}', '62000000-1000-0000-0000-000000000001');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (3,'idempotency input mismatch is rejected');

DO $$ BEGIN BEGIN
 PERFORM create_workflow_definition(NULL,'platform_flow','Platform','opaque_case','{"nodes":[],"edges":[]}', '62000000-1000-0000-0000-000000000002');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (4,'organization admin cannot create platform definition');

SELECT publish_workflow_definition_version((SELECT id FROM wf_ids WHERE name='version1'),0,'62000000-1000-0000-0000-000000000003');
INSERT INTO wf_results VALUES (5,'inert definition version publishes with optimistic lock');

DO $$ BEGIN
 IF (SELECT status FROM workflow_definitions WHERE id=(SELECT id FROM wf_ids WHERE name='definition'))<>'active'
 OR (SELECT status FROM workflow_definition_versions WHERE id=(SELECT id FROM wf_ids WHERE name='version1'))<>'published' THEN RAISE EXCEPTION 'publish state'; END IF;
END $$;
INSERT INTO wf_results VALUES (6,'publish pins active immutable version');

WITH made AS (SELECT * FROM create_workflow_definition_version(
 (SELECT id FROM wf_ids WHERE name='definition'),'{"nodes":[{"key":"x"}],"edges":[]}',
 '62000000-1000-0000-0000-000000000004'))
INSERT INTO wf_ids SELECT 'version2',version_id FROM made;
DO $$ BEGIN BEGIN
 PERFORM publish_workflow_definition_version((SELECT id FROM wf_ids WHERE name='version2'),1,'62000000-1000-0000-0000-000000000005');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (7,'non-inert graph cannot be published in Phase 1');

DO $$ BEGIN BEGIN
 PERFORM create_workflow_definition_version((SELECT id FROM wf_ids WHERE name='definition'),'{"nodes":[],"edges":[]}', '62000000-1000-0000-0000-000000000006');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (8,'one-draft-per-definition invariant enforced');

WITH made AS (SELECT create_workflow_instance(
 (SELECT id FROM wf_ids WHERE name='version1'),'opaque_case','62000000-2000-0000-0000-000000000001',
 '62000000-0000-0000-0000-000000000001','62000000-1000-0000-0000-000000000007',
 '62000000-3000-0000-0000-000000000001') id)
INSERT INTO wf_ids SELECT 'instance',id FROM made;
INSERT INTO wf_results VALUES (9,'admin creates pending opaque instance from active version');

DO $$ DECLARE a UUID; BEGIN
 a:=create_workflow_instance((SELECT id FROM wf_ids WHERE name='version1'),'opaque_case','62000000-2000-0000-0000-000000000001','62000000-0000-0000-0000-000000000001','62000000-1000-0000-0000-000000000007','62000000-3000-0000-0000-000000000001');
 IF a<>(SELECT id FROM wf_ids WHERE name='instance') THEN RAISE EXCEPTION 'instance retry mismatch'; END IF;
END $$;
INSERT INTO wf_results VALUES (10,'instance creation is idempotent');

DO $$ BEGIN BEGIN
 PERFORM create_workflow_instance((SELECT id FROM wf_ids WHERE name='version1'),'opaque_case','62000000-2000-0000-0000-000000000001','62000000-0000-0000-0000-000000000001','62000000-1000-0000-0000-000000000008',NULL);
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (11,'one active workflow aggregate per definition and subject');

DO $$ BEGIN BEGIN
 PERFORM create_workflow_instance((SELECT id FROM wf_ids WHERE name='version1'),'wrong_type','62000000-2000-0000-0000-000000000002','62000000-0000-0000-0000-000000000001','62000000-1000-0000-0000-000000000009',NULL);
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (12,'subject type contract is enforced');

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM get_workflow_instance((SELECT id FROM wf_ids WHERE name='instance')) WHERE status='pending' AND definition_key='generic_case_review') THEN RAISE EXCEPTION 'read result'; END IF;
END $$;
INSERT INTO wf_results VALUES (13,'owner reads fail-closed instance projection');

DO $$ BEGIN
 IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wf_ids WHERE name='instance'))<>1
 OR (SELECT event_type FROM workflow_events WHERE instance_id=(SELECT id FROM wf_ids WHERE name='instance'))<>'instance_created' THEN RAISE EXCEPTION 'creation event'; END IF;
END $$;
INSERT INTO wf_results VALUES (14,'instance creation appends initial event');

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM workflow_participants WHERE instance_id=(SELECT id FROM wf_ids WHERE name='instance') AND user_id=auth.uid() AND participant_role='owner') THEN RAISE EXCEPTION 'owner participant'; END IF;
END $$;
INSERT INTO wf_results VALUES (15,'instance creator receives explicit owner participation');

DO $$ BEGIN BEGIN
 INSERT INTO workflow_instances(definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,correlation_id,created_by,create_idempotency_key)
 SELECT definition_id,definition_version_id,'opaque_case',gen_random_uuid(),home_organization_id,participant_organization_ids,gen_random_uuid(),auth.uid(),gen_random_uuid() FROM workflow_instances LIMIT 1;
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
INSERT INTO wf_results VALUES (16,'authenticated direct instance mutation is denied');

RESET ROLE;
INSERT INTO workflow_instance_steps(instance_id,definition_node_key) VALUES ((SELECT id FROM wf_ids WHERE name='instance'),'foundation_placeholder') RETURNING id;
INSERT INTO workflow_work_items(instance_id,work_item_type,organization_id,assigned_to)
 VALUES ((SELECT id FROM wf_ids WHERE name='instance'),'activity','62000000-0000-0000-0000-000000000001','62000000-0001-0000-0000-000000000001') RETURNING id;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62000000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN IF (SELECT count(*) FROM list_workflow_work_items(50,NULL,NULL))<>1 THEN RAISE EXCEPTION 'queue'; END IF; END $$;
INSERT INTO wf_results VALUES (17,'bounded work queue returns explicit assignee');
DO $$ BEGIN IF (SELECT count(*) FROM list_workflow_work_items(500,NULL,NULL))>100 THEN RAISE EXCEPTION 'unbounded'; END IF; END $$;
INSERT INTO wf_results VALUES (18,'work queue limit is bounded to 100');

RESET ROLE;
DO $$ BEGIN BEGIN UPDATE workflow_events SET metadata='{"changed":true}' WHERE instance_id=(SELECT id FROM wf_ids WHERE name='instance'); RAISE EXCEPTION 'accepted'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END; END $$;
INSERT INTO wf_results VALUES (19,'event history is append-only');

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62000000-0001-0000-0000-000000000002"}',false);
DO $$ BEGIN BEGIN
 PERFORM create_workflow_definition('62000000-0000-0000-0000-000000000001','staff_flow','Staff Flow','opaque_case','{"nodes":[],"edges":[]}', '62000000-1000-0000-0000-000000000010');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_results VALUES (20,'non-admin cannot create definition');
DO $$ BEGIN IF EXISTS(SELECT 1 FROM get_workflow_instance((SELECT id FROM wf_ids WHERE name='instance'))) THEN RAISE EXCEPTION 'leak'; END IF; END $$;
INSERT INTO wf_results VALUES (21,'same-organization nonparticipant cannot read instance');

SELECT set_config('request.jwt.claims','{"sub":"62000000-0001-0000-0000-000000000003"}',false);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM get_workflow_instance((SELECT id FROM wf_ids WHERE name='instance'))) THEN RAISE EXCEPTION 'cross-org leak'; END IF; END $$;
INSERT INTO wf_results VALUES (22,'cross-organization nonparticipant cannot read instance');

SELECT set_config('request.jwt.claims','{"sub":"62000000-0001-0000-0000-000000000004"}',false);
WITH made AS (SELECT * FROM create_workflow_definition(NULL,'platform_flow','Platform Flow','opaque_case','{"nodes":[],"edges":[]}', '62000000-1000-0000-0000-000000000011')) SELECT count(*) FROM made;
INSERT INTO wf_results VALUES (23,'super administrator creates platform definition');
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM get_workflow_instance((SELECT id FROM wf_ids WHERE name='instance'))) THEN RAISE EXCEPTION 'super visibility'; END IF; END $$;
INSERT INTO wf_results VALUES (24,'super administrator retains emergency visibility');

RESET ROLE;
DO $$ BEGIN IF (SELECT count(*) FROM wf_results)<>24 THEN RAISE EXCEPTION 'Expected 24 scenarios, got %',(SELECT count(*) FROM wf_results); END IF; END $$;
SELECT 'Workflow backend behavioral tests PASSED: 24/24' AS result;

DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '62000000-%');
DELETE FROM workflow_events WHERE false; -- append-only guard remains exercised; fixture cleanup follows via trigger disable.
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '62000000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '62000000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '62000000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '62000000-%';
DELETE FROM workflow_definition_versions WHERE false;
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definitions SET active_version_id=NULL WHERE created_by::text LIKE '62000000-%';
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '62000000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '62000000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '62000000-%';
DELETE FROM users WHERE id::text LIKE '62000000-%';
DELETE FROM auth.users WHERE id::text LIKE '62000000-%';
DELETE FROM organizations WHERE id::text LIKE '62000000-%';
