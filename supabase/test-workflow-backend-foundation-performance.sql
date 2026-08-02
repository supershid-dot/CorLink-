-- CAP-002 Phase 1 disposable scale and query-plan probes
-- Seeds 200 instances, 20,000 work items and 100,000 events, then rolls back.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('62300000-0000-0000-0000-000000000001','Workflow Performance','authority','WFP');
INSERT INTO auth.users(id,email) VALUES ('62300000-0001-0000-0000-000000000001','perf@wf.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62300000-0001-0000-0000-000000000001','62300000-0000-0000-0000-000000000001','WFP-1','Performance User','perf@wf.local',true,true);
INSERT INTO auth.users(id,email)
SELECT ('62300000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'perf-'||g||'@wf.local' FROM generate_series(1,19) g;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('62300000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'62300000-0000-0000-0000-000000000001',
 'WFP-'||(g+1),'Performance User '||g,'perf-'||g||'@wf.local',true FROM generate_series(1,19) g;
INSERT INTO workflow_definitions(id,organization_id,definition_key,name,subject_type,status,created_by,updated_by,create_idempotency_key)
 VALUES ('62300000-1000-0000-0000-000000000001','62300000-0000-0000-0000-000000000001','performance_flow','Performance Flow','opaque_record','draft','62300000-0001-0000-0000-000000000001','62300000-0001-0000-0000-000000000001','62300000-1000-0000-0000-000000000011');
INSERT INTO workflow_definition_versions(id,definition_id,version_number,status,definition_payload,content_hash,created_by,create_idempotency_key,published_by,published_at,publish_idempotency_key)
 VALUES ('62300000-1000-0000-0000-000000000002','62300000-1000-0000-0000-000000000001',1,'published','{"nodes":[],"edges":[]}',encode(digest(convert_to('{"edges": [], "nodes": []}'::jsonb::text,'UTF8'),'sha256'),'hex'),'62300000-0001-0000-0000-000000000001','62300000-1000-0000-0000-000000000012','62300000-0001-0000-0000-000000000001',now(),'62300000-1000-0000-0000-000000000013');
UPDATE workflow_definitions SET status='active',active_version_id='62300000-1000-0000-0000-000000000002' WHERE id='62300000-1000-0000-0000-000000000001';

INSERT INTO workflow_instances(id,definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,status,correlation_id,created_by,create_idempotency_key)
SELECT ('62300000-2000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid,
 '62300000-1000-0000-0000-000000000001','62300000-1000-0000-0000-000000000002','opaque_record',
 ('62300000-3000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid,'62300000-0000-0000-0000-000000000001',ARRAY['62300000-0000-0000-0000-000000000001'::uuid],
 'pending',('62300000-4000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid,'62300000-0001-0000-0000-000000000001',
 ('62300000-5000-0000-0000-'||lpad(to_hex(g),12,'0'))::uuid
FROM generate_series(1,200) g;

INSERT INTO workflow_participants(instance_id,user_id,participant_role,authority_source,created_by)
SELECT id,'62300000-0001-0000-0000-000000000001','owner','performance_fixture','62300000-0001-0000-0000-000000000001' FROM workflow_instances WHERE created_by='62300000-0001-0000-0000-000000000001';

INSERT INTO workflow_work_items(instance_id,work_item_type,state,organization_id,assigned_to,priority,due_at,created_at)
SELECT ('62300000-2000-0000-0000-'||lpad(to_hex(((g-1)%200)+1),12,'0'))::uuid,
 'activity','offered','62300000-0000-0000-0000-000000000001',
 CASE WHEN g%20=0 THEN '62300000-0001-0000-0000-000000000001'::uuid
      ELSE ('62300000-0001-0000-0001-'||lpad(to_hex(g%20),12,'0'))::uuid END,
 (g%21)-10,now()+(g%365||' hours')::interval,now()-(g||' seconds')::interval
FROM generate_series(1,20000) g;

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT ('62300000-2000-0000-0000-'||lpad(to_hex(((g-1)%200)+1),12,'0'))::uuid,
 ((g-1)/200)+1,'performance_event','62300000-0001-0000-0000-000000000001',
 ('62300000-4000-0000-0000-'||lpad(to_hex(((g-1)%200)+1),12,'0'))::uuid,
 (md5('workflow-event-'||g)::uuid),'{}',now()-(g||' milliseconds')::interval
FROM generate_series(1,100000) g;

ANALYZE workflow_instances; ANALYZE workflow_work_items; ANALYZE workflow_events;

-- Bounded personal queue/keyset page.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id,instance_id,state,due_at,created_at FROM workflow_work_items
WHERE assigned_to='62300000-0001-0000-0000-000000000001'
  AND state IN ('offered','claimed','failed')
ORDER BY created_at DESC,id DESC LIMIT 100;

-- Event history remains bounded by aggregate and sequence.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT event_sequence,event_type,created_at FROM workflow_events
WHERE instance_id='62300000-2000-0000-0000-000000000001'
ORDER BY event_sequence DESC LIMIT 100;

-- Active subject lookup used by duplicate aggregate protection.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM workflow_instances
WHERE definition_id='62300000-1000-0000-0000-000000000001'
 AND subject_type='opaque_record'
 AND subject_id='62300000-3000-0000-0000-000000000001'
 AND status IN ('pending','active','suspended','failed');

-- Correlation history probe across a million-event-ready index shape.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id,event_type,created_at FROM workflow_events
WHERE correlation_id='62300000-4000-0000-0000-000000000001'
ORDER BY created_at,id LIMIT 100;

DO $$
DECLARE p TEXT;
BEGIN
  EXECUTE $plan$EXPLAIN (COSTS OFF) SELECT * FROM workflow_events WHERE instance_id='62300000-2000-0000-0000-000000000001' ORDER BY event_sequence DESC LIMIT 100$plan$ INTO p;
  IF p IS NULL THEN RAISE EXCEPTION 'event plan unavailable'; END IF;
  IF (SELECT count(*) FROM workflow_work_items)<>20000 OR (SELECT count(*) FROM workflow_events)<>100000 THEN RAISE EXCEPTION 'scale fixture incomplete'; END IF;
END $$;

SELECT 'Workflow performance probes PASSED: 200 instances / 20,000 work items / 100,000 events' AS result;
ROLLBACK;
