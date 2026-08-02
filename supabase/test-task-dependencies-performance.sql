-- CorLink — T3F.1 disposable 10,000-Task dependency performance probe
\set ON_ERROR_STOP on
\timing on

INSERT INTO organizations(id,name,type,code)
VALUES('f3000000-0000-0000-0000-000000000001','T3F1 Performance','authority','T3F1P');
INSERT INTO auth.users(id,email)
VALUES('f3000000-0001-0000-0000-000000000001','performance@t3f1.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin)
VALUES('f3000000-0001-0000-0000-000000000001','f3000000-0000-0000-0000-000000000001','T3F1-P1','Performance Owner','performance@t3f1.local',true,true);

INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,visibility)
SELECT md5('t3f1-performance-task-'||n)::UUID,
       'T3F1-P-'||lpad(n::TEXT,5,'0'),
       'Performance Task '||n,'open','normal',
       'f3000000-0001-0000-0000-000000000001',
       'f3000000-0000-0000-0000-000000000001','private'
FROM generate_series(1,10000) n;

-- A 1,000-deep acyclic chain: 1 depends_on 2 ... 999 depends_on 1000.
INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by)
SELECT md5('t3f1-performance-task-'||n)::UUID,
       md5('t3f1-performance-task-'||(n+1))::UUID,
       'f3000000-0000-0000-0000-000000000001',
       'f3000000-0001-0000-0000-000000000001'
FROM generate_series(1,999) n;

-- Wide fan-out: Task 10,000 depends on Tasks 1,001..9,999 (8,999 edges).
INSERT INTO task_dependencies(dependent_task_id,prerequisite_task_id,organization_id,created_by)
SELECT md5('t3f1-performance-task-10000')::UUID,
       md5('t3f1-performance-task-'||n)::UUID,
       'f3000000-0000-0000-0000-000000000001',
       'f3000000-0001-0000-0000-000000000001'
FROM generate_series(1001,9999) n;

ANALYZE tasks;
ANALYZE task_dependencies;

-- Active list by dependent; expected dependent partial index.
EXPLAIN (ANALYZE, BUFFERS)
SELECT td.id,td.prerequisite_task_id,td.created_at
FROM task_dependencies td
WHERE td.dependent_task_id=md5('t3f1-performance-task-10000')::UUID
  AND td.removed_at IS NULL
ORDER BY td.created_at DESC,td.id DESC
LIMIT 100;

-- Reverse list by prerequisite; expected prerequisite partial index.
EXPLAIN (ANALYZE, BUFFERS)
SELECT td.id,td.dependent_task_id,td.created_at
FROM task_dependencies td
WHERE td.prerequisite_task_id=md5('t3f1-performance-task-1001')::UUID
  AND td.removed_at IS NULL
ORDER BY td.created_at DESC,td.id DESC
LIMIT 100;

-- Worst test graph cycle probe traverses the 1,000-deep chain.
EXPLAIN (ANALYZE, BUFFERS)
SELECT task_dependency_would_cycle(
  md5('t3f1-performance-task-1000')::UUID,
  md5('t3f1-performance-task-1')::UUID
);

-- Derived state scans the 8,999-prerequisite fan-out once.
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM get_task_dependency_state(md5('t3f1-performance-task-10000')::UUID);

DO $$
DECLARE
  v_started TIMESTAMPTZ;
  v_elapsed DOUBLE PRECISION;
  v_state RECORD;
BEGIN
  v_started:=clock_timestamp();
  PERFORM task_dependency_would_cycle(md5('t3f1-performance-task-1000')::UUID,md5('t3f1-performance-task-1')::UUID);
  v_elapsed:=extract(epoch FROM clock_timestamp()-v_started)*1000;
  RAISE NOTICE 'PERFORMANCE cycle_check_1000_depth_ms=%',round(v_elapsed::NUMERIC,3);

  v_started:=clock_timestamp();
  SELECT * INTO v_state FROM get_task_dependency_state(md5('t3f1-performance-task-10000')::UUID);
  v_elapsed:=extract(epoch FROM clock_timestamp()-v_started)*1000;
  IF v_state.active_prerequisite_count<>8999 OR v_state.unresolved_prerequisite_count<>8999 OR NOT v_state.is_blocked THEN
    RAISE EXCEPTION 'wide state mismatch: %',row_to_json(v_state);
  END IF;
  RAISE NOTICE 'PERFORMANCE blocked_state_8999_edges_ms=%',round(v_elapsed::NUMERIC,3);
  RAISE NOTICE 'TASK DEPENDENCY PERFORMANCE: 10000 tasks, 9998 edges, 1000 depth/fan-out probes PASSED';
END $$;

DELETE FROM task_dependencies WHERE organization_id='f3000000-0000-0000-0000-000000000001';
DELETE FROM tasks WHERE organization_id='f3000000-0000-0000-0000-000000000001';
DELETE FROM users WHERE id='f3000000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='f3000000-0001-0000-0000-000000000001';
DELETE FROM organizations WHERE id='f3000000-0000-0000-0000-000000000001';
