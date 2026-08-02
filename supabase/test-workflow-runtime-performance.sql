-- CAP-002 Phase 2 runtime performance probes over 100,000 aggregate events
-- Disposable local PostgreSQL only; rolls back all fixtures.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('62800000-0000-0000-0000-000000000001','Workflow Runtime Performance','authority','WRP');
INSERT INTO auth.users(id,email) VALUES ('62800000-0001-0000-0000-000000000001','admin@wrp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('62800000-0001-0000-0000-000000000001','62800000-0000-0000-0000-000000000001','WRP-1','Runtime Performance Admin','admin@wrp.local',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62800000-0001-0000-0000-000000000001"}',true);
CREATE TEMP TABLE wf_runtime_perf_definition AS
SELECT * FROM create_workflow_definition('62800000-0000-0000-0000-000000000001','runtime_performance_flow','Runtime Performance','opaque_record','{"nodes":[],"edges":[]}','62800000-1000-0000-0000-000000000001');
SELECT publish_workflow_definition_version((SELECT version_id FROM wf_runtime_perf_definition),0,'62800000-1000-0000-0000-000000000002');
CREATE TEMP TABLE wf_runtime_perf_instance AS
SELECT create_workflow_instance((SELECT version_id FROM wf_runtime_perf_definition),'opaque_record','62800000-2000-0000-0000-000000000001','62800000-0000-0000-0000-000000000001','62800000-3000-0000-0000-000000000001','62800000-4000-0000-0000-000000000001') instance_id;
RESET ROLE;

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT (SELECT instance_id FROM wf_runtime_perf_instance),g,'history_fixture','62800000-0001-0000-0000-000000000001',
 '62800000-4000-0000-0000-000000000001',md5('runtime-event-'||g)::UUID,'{}',now()-(g||' milliseconds')::INTERVAL
FROM generate_series(2,100000) g;
UPDATE workflow_instances SET next_event_sequence=100001 WHERE id=(SELECT instance_id FROM wf_runtime_perf_instance);
ANALYZE workflow_instances; ANALYZE workflow_events; ANALYZE workflow_participants;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62800000-0001-0000-0000-000000000001"}',true);

-- Aggregate transition remains bounded by one PK row lock and one event append.
EXPLAIN (ANALYZE,BUFFERS,COSTS OFF)
SELECT * FROM start_workflow_instance((SELECT instance_id FROM wf_runtime_perf_instance),0,'62800000-5000-0000-0000-000000000001');

-- Idempotent replay uses the per-instance event idempotency unique index.
EXPLAIN (ANALYZE,BUFFERS,COSTS OFF)
SELECT * FROM start_workflow_instance((SELECT instance_id FROM wf_runtime_perf_instance),0,'62800000-5000-0000-0000-000000000001');

-- Recent aggregate history remains a bounded descending index page.
EXPLAIN (ANALYZE,BUFFERS,COSTS OFF)
SELECT event_sequence,event_type,created_at FROM workflow_events
WHERE instance_id=(SELECT instance_id FROM wf_runtime_perf_instance)
ORDER BY event_sequence DESC LIMIT 100;

RESET ROLE;
DO $$ BEGIN
 IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT instance_id FROM wf_runtime_perf_instance))<>100001 THEN RAISE EXCEPTION 'event fixture or append mismatch'; END IF;
 IF (SELECT max(event_sequence) FROM workflow_events WHERE instance_id=(SELECT instance_id FROM wf_runtime_perf_instance))<>100001 THEN RAISE EXCEPTION 'runtime event sequence mismatch'; END IF;
 IF (SELECT lock_version FROM workflow_instances WHERE id=(SELECT instance_id FROM wf_runtime_perf_instance))<>1 THEN RAISE EXCEPTION 'replay mutated aggregate'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE indexname='workflow_events_idempotency_unique')
    OR NOT EXISTS(SELECT 1 FROM pg_indexes WHERE indexname='idx_workflow_events_instance_sequence') THEN RAISE EXCEPTION 'runtime event indexes missing'; END IF;
END $$;
SELECT 'Workflow runtime performance probes PASSED: transition and replay over 100,000-event aggregate' AS result;
ROLLBACK;
