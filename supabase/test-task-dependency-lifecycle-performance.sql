-- CorLink - T3F.2 disposable dependency-state performance probes
\set ON_ERROR_STOP on
\timing on

INSERT INTO organizations(id,name,type,code)
VALUES('f7000000-0000-0000-0000-000000000001','T3F2 Performance','authority','T3F2P');
INSERT INTO auth.users(id,email)
VALUES('f7000000-0001-0000-0000-000000000001','performance@t3f2.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin)
VALUES('f7000000-0001-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','T3F2-P1','Performance Owner','performance@t3f2.local',true,true);

INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,visibility)
SELECT md5('t3f2-lifecycle-task-'||n)::UUID,
       'T3F2-P-'||lpad(n::TEXT,5,'0'),
       'Lifecycle Performance Task '||n,
       'open','normal','f7000000-0001-0000-0000-000000000001',
       'f7000000-0000-0000-0000-000000000001','private'
FROM generate_series(1,1115) n;

-- Task 1: zero prerequisites. Task 2: one. Task 3: ten.
-- Task 4: one hundred. Task 5: one thousand (wider practical fan-out).
INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by)
SELECT md5('t3f2-lifecycle-task-2')::UUID,md5('t3f2-lifecycle-task-101')::UUID,
       'f7000000-0000-0000-0000-000000000001'::UUID,'f7000000-0001-0000-0000-000000000001'::UUID
UNION ALL
SELECT md5('t3f2-lifecycle-task-3')::UUID,md5('t3f2-lifecycle-task-'||n)::UUID,
       'f7000000-0000-0000-0000-000000000001','f7000000-0001-0000-0000-000000000001'
FROM generate_series(201,210) n
UNION ALL
SELECT md5('t3f2-lifecycle-task-4')::UUID,md5('t3f2-lifecycle-task-'||n)::UUID,
       'f7000000-0000-0000-0000-000000000001','f7000000-0001-0000-0000-000000000001'
FROM generate_series(301,400) n
UNION ALL
SELECT md5('t3f2-lifecycle-task-5')::UUID,md5('t3f2-lifecycle-task-'||n)::UUID,
       'f7000000-0000-0000-0000-000000000001','f7000000-0001-0000-0000-000000000001'
FROM generate_series(101,1100) n;

ANALYZE tasks;
ANALYZE task_dependencies;

-- The authoritative helper used by update_task()/complete_task().
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM get_task_dependency_state(md5('t3f2-lifecycle-task-5')::UUID);

-- The equivalent hot lookup must use T3F.1's dependent partial index.
EXPLAIN (ANALYZE, BUFFERS)
SELECT td.id
FROM task_dependencies td
JOIN tasks prerequisite ON prerequisite.id=td.prerequisite_task_id
WHERE td.dependent_task_id=md5('t3f2-lifecycle-task-5')::UUID
  AND td.removed_at IS NULL
  AND prerequisite.status<>'completed'
LIMIT 1;

DO $$
DECLARE
  v_started TIMESTAMPTZ;
  v_elapsed NUMERIC;
  v_state RECORD;
  v_case RECORD;
BEGIN
  FOR v_case IN SELECT * FROM (VALUES (1,0),(2,1),(3,10),(4,100),(5,1000)) x(task_n,expected_count)
  LOOP
    v_started:=clock_timestamp();
    SELECT * INTO v_state FROM get_task_dependency_state(md5('t3f2-lifecycle-task-'||v_case.task_n)::UUID);
    v_elapsed:=extract(epoch FROM clock_timestamp()-v_started)*1000;
    IF v_state.active_prerequisite_count<>v_case.expected_count
       OR v_state.unresolved_prerequisite_count<>v_case.expected_count
       OR v_state.is_blocked<>(v_case.expected_count>0) THEN
      RAISE EXCEPTION 'state mismatch for % prerequisites: %',v_case.expected_count,row_to_json(v_state);
    END IF;
    RAISE NOTICE 'PERFORMANCE dependency_state_%_prerequisites_ms=%',v_case.expected_count,round(v_elapsed,3);
  END LOOP;
  RAISE NOTICE 'TASK DEPENDENCY LIFECYCLE PERFORMANCE: 0/1/10/100/1000 PREREQUISITE PROBES PASSED';
END $$;

DELETE FROM task_dependencies WHERE organization_id='f7000000-0000-0000-0000-000000000001';
DELETE FROM tasks WHERE organization_id='f7000000-0000-0000-0000-000000000001';
DELETE FROM users WHERE id='f7000000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='f7000000-0001-0000-0000-000000000001';
DELETE FROM organizations WHERE id='f7000000-0000-0000-0000-000000000001';
