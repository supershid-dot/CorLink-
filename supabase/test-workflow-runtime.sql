-- CAP-002 Phase 2 authenticated runtime behavior suite (22 scenarios)
-- Disposable local PostgreSQL only; one transaction leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf_runtime_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf_runtime_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
CREATE TEMP TABLE wf_runtime_baseline AS
SELECT (SELECT count(*) FROM requests) requests_count,
       (SELECT count(*) FROM external_correspondence) entries_count,
       (SELECT count(*) FROM internal_requests) internal_count,
       (SELECT count(*) FROM prisoner_letters) letters_count,
       (SELECT count(*) FROM meetings) meetings_count,
       (SELECT count(*) FROM tasks) tasks_count,
       (SELECT count(*) FROM notifications) notifications_count,
       (SELECT count(*) FROM audit_logs) audit_count;
GRANT SELECT,INSERT ON wf_runtime_results,wf_runtime_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('62400000-0000-0000-0000-000000000001','Workflow Runtime Org','authority','WRT');
INSERT INTO auth.users(id,email) VALUES
 ('62400000-0001-0000-0000-000000000001','admin@wrt.local'),
 ('62400000-0001-0000-0000-000000000002','viewer@wrt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('62400000-0001-0000-0000-000000000001','62400000-0000-0000-0000-000000000001','WRT-1','Runtime Admin','admin@wrt.local',true),
 ('62400000-0001-0000-0000-000000000002','62400000-0000-0000-0000-000000000001','WRT-2','Runtime Viewer','viewer@wrt.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('62400000-0001-0000-0000-000000000001','organization','62400000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('62400000-0001-0000-0000-000000000002','organization','62400000-0000-0000-0000-000000000001','staff',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62400000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition(
 '62400000-0000-0000-0000-000000000001','runtime_flow','Runtime Flow','opaque_record',
 '{"nodes":[],"edges":[]}','62400000-1000-0000-0000-000000000001'))
INSERT INTO wf_runtime_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf_runtime_ids WHERE name='version'),0,'62400000-1000-0000-0000-000000000002');

INSERT INTO wf_runtime_ids
SELECT 'instance_'||g,create_workflow_instance(
 (SELECT id FROM wf_runtime_ids WHERE name='version'),'opaque_record',
 ('62400000-2000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid,
 '62400000-0000-0000-0000-000000000001',
 ('62400000-3000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid,NULL)
FROM generate_series(1,6) g;

DO $$ DECLARE r RECORD; BEGIN
 SELECT * INTO r FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),0,'62400000-4000-0000-0000-000000000001');
 IF r.status<>'active' OR r.lock_version<>1 OR r.event_sequence<>2 OR r.replayed THEN RAISE EXCEPTION 'start result %',row_to_json(r); END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(1,'pending instance starts active');
DO $$ BEGIN IF (SELECT started_at IS NULL FROM workflow_instances WHERE id=(SELECT id FROM wf_runtime_ids WHERE name='instance_1')) THEN RAISE EXCEPTION 'start timestamp'; END IF; END $$;
INSERT INTO wf_runtime_results VALUES(2,'start records start time and version');

DO $$ DECLARE first_event UUID; r RECORD; BEGIN
 SELECT id INTO first_event FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_ids WHERE name='instance_1') AND event_type='instance_started';
 SELECT * INTO r FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),0,'62400000-4000-0000-0000-000000000001');
 IF NOT r.replayed OR r.event_id<>first_event OR r.lock_version<>1 THEN RAISE EXCEPTION 'replay result'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(3,'identical start retry replays exact result');

DO $$ BEGIN BEGIN
 PERFORM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),0,'62400000-4000-0000-0000-000000000001'::uuid);
 PERFORM suspend_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),1,'62400000-4000-0000-0000-000000000001','manual_pause');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='accepted' THEN RAISE; END IF; END;
END $$;
INSERT INTO wf_runtime_results VALUES(4,'idempotency key cannot be reused for another command');

DO $$ BEGIN BEGIN
 PERFORM suspend_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),0,'62400000-4000-0000-0000-000000000002','manual_pause');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN serialization_failure THEN NULL; END;
END $$;
INSERT INTO wf_runtime_results VALUES(5,'stale optimistic version is rejected');

DO $$ DECLARE r RECORD; BEGIN
 SELECT * INTO r FROM suspend_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),1,'62400000-4000-0000-0000-000000000003','manual_pause');
 IF r.status<>'suspended' OR r.lock_version<>2 THEN RAISE EXCEPTION 'suspend'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(6,'active instance suspends');
DO $$ DECLARE r RECORD; BEGIN
 SELECT * INTO r FROM resume_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),2,'62400000-4000-0000-0000-000000000004','manual_resume');
 IF r.status<>'active' OR r.lock_version<>3 THEN RAISE EXCEPTION 'resume'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(7,'suspended instance resumes');
DO $$ DECLARE r RECORD; BEGIN
 SELECT * INTO r FROM complete_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),3,'62400000-4000-0000-0000-000000000005','success');
 IF r.status<>'completed' OR r.terminal_outcome<>'success' OR r.lock_version<>4 THEN RAISE EXCEPTION 'complete'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(8,'active instance completes with safe outcome');
DO $$ DECLARE r RECORD; BEGIN
 SELECT * INTO r FROM complete_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),3,'62400000-4000-0000-0000-000000000005','success');
 IF NOT r.replayed OR r.status<>'completed' OR r.lock_version<>4 THEN RAISE EXCEPTION 'complete replay'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(9,'completion retry is idempotent');
DO $$ BEGIN BEGIN
 PERFORM complete_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_1'),4,'62400000-4000-0000-0000-000000000006','success');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
END $$;
INSERT INTO wf_runtime_results VALUES(10,'duplicate completion with new command is illegal');

SELECT * FROM cancel_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_2'),0,'62400000-4000-0000-0000-000000000007','owner_cancelled');
INSERT INTO wf_runtime_results VALUES(11,'pending instance cancels');
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_3'),0,'62400000-4000-0000-0000-000000000008');
SELECT * FROM cancel_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_3'),1,'62400000-4000-0000-0000-000000000009','owner_cancelled');
INSERT INTO wf_runtime_results VALUES(12,'active instance cancels');
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_4'),0,'62400000-4000-0000-0000-000000000010');
SELECT * FROM suspend_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_4'),1,'62400000-4000-0000-0000-000000000011','manual_pause');
SELECT * FROM cancel_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_4'),2,'62400000-4000-0000-0000-000000000012','owner_cancelled');
INSERT INTO wf_runtime_results VALUES(13,'suspended instance cancels');

DO $$ BEGIN BEGIN
 PERFORM suspend_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_5'),0,'62400000-4000-0000-0000-000000000013','Unsafe reason');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
INSERT INTO wf_runtime_results VALUES(14,'unsafe reason code is rejected');
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_5'),0,'62400000-4000-0000-0000-000000000014');
DO $$ BEGIN BEGIN
 PERFORM complete_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_5'),1,'62400000-4000-0000-0000-000000000015','Unsafe outcome');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
INSERT INTO wf_runtime_results VALUES(15,'unsafe outcome code is rejected');

DO $$ BEGIN
 IF EXISTS (
   SELECT 1 FROM (
     SELECT event_sequence,lag(event_sequence) OVER(ORDER BY event_sequence) prior
     FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_ids WHERE name='instance_1')
   ) e WHERE prior IS NOT NULL AND event_sequence<>prior+1
 ) THEN RAISE EXCEPTION 'event gap'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(16,'runtime events are strictly sequenced per instance');
DO $$ BEGIN
 IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wf_runtime_ids WHERE name='instance_5'))<>2 THEN RAISE EXCEPTION 'failed command event'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(17,'failed commands append no success event');

RESET ROLE;
INSERT INTO workflow_instance_steps(id,instance_id,definition_node_key,state)
VALUES ('62400000-6000-0000-0000-000000000001',(SELECT id FROM wf_runtime_ids WHERE name='instance_6'),'runtime_fixture','active');
INSERT INTO workflow_tokens(id,instance_id,step_id,token_key,state)
VALUES ('62400000-6000-0000-0000-000000000002',(SELECT id FROM wf_runtime_ids WHERE name='instance_6'),'62400000-6000-0000-0000-000000000001','runtime_token','active');
INSERT INTO workflow_work_items(id,instance_id,step_id,token_id,work_item_type,state,organization_id,assigned_to)
VALUES ('62400000-6000-0000-0000-000000000003',(SELECT id FROM wf_runtime_ids WHERE name='instance_6'),'62400000-6000-0000-0000-000000000001','62400000-6000-0000-0000-000000000002','activity','offered','62400000-0000-0000-0000-000000000001','62400000-0001-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62400000-0001-0000-0000-000000000001"}',true);
SELECT * FROM start_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_6'),0,'62400000-4000-0000-0000-000000000016');
INSERT INTO wf_runtime_results VALUES(18,'runtime aggregate with open work may start');
DO $$ BEGIN BEGIN
 PERFORM complete_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_6'),1,'62400000-4000-0000-0000-000000000017','success');
 RAISE EXCEPTION 'accepted'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
END $$;
INSERT INTO wf_runtime_results VALUES(19,'open runtime work prevents completion');
SELECT * FROM cancel_workflow_instance((SELECT id FROM wf_runtime_ids WHERE name='instance_6'),1,'62400000-4000-0000-0000-000000000018','owner_cancelled');
INSERT INTO wf_runtime_results VALUES(20,'cancellation terminates aggregate with open work');
RESET ROLE;
DO $$ BEGIN
 IF (SELECT state FROM workflow_instance_steps WHERE id='62400000-6000-0000-0000-000000000001')<>'cancelled'
 OR (SELECT state FROM workflow_tokens WHERE id='62400000-6000-0000-0000-000000000002')<>'cancelled'
 OR (SELECT state FROM workflow_work_items WHERE id='62400000-6000-0000-0000-000000000003')<>'cancelled'
 THEN RAISE EXCEPTION 'open runtime rows not cancelled'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(21,'cancellation closes open steps tokens and work items');

DO $$ BEGIN
 IF (SELECT requests_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM requests)
 OR (SELECT entries_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM external_correspondence)
 OR (SELECT internal_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM internal_requests)
 OR (SELECT letters_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM prisoner_letters)
 OR (SELECT meetings_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM meetings)
 OR (SELECT tasks_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM tasks)
 OR (SELECT notifications_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM notifications)
 OR (SELECT audit_count FROM wf_runtime_baseline)<>(SELECT count(*) FROM audit_logs)
 THEN RAISE EXCEPTION 'out-of-scope table mutation'; END IF;
END $$;
INSERT INTO wf_runtime_results VALUES(22,'runtime creates no module audit or notification side effects');

DO $$ BEGIN IF (SELECT count(*) FROM wf_runtime_results)<>22 THEN RAISE EXCEPTION 'Expected 22 scenarios'; END IF; END $$;
SELECT 'Workflow runtime behavioral tests PASSED: 22/22' AS result;
ROLLBACK;
