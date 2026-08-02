-- CorLink — T3F.2A disposable candidate-search performance probe
\set ON_ERROR_STOP on
\timing on

INSERT INTO organizations(id,name,type,code) VALUES('f7100000-0000-0000-0000-000000000001','T3F2A Perf Org','authority','T3F2AP');
INSERT INTO divisions(id,name,org_id) VALUES('f7100000-0000-0000-0000-000000000011','T3F2A Perf Division','f7100000-0000-0000-0000-000000000001');
INSERT INTO sections(id,name,code,org_id,division_id) VALUES('f7100000-0000-0000-0000-000000000021','T3F2A Perf Section','T3F2APS','f7100000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000011');
INSERT INTO auth.users(id,email) VALUES('f7100000-0001-0000-0000-000000000001','perf@t3f2a.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES('f7100000-0001-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','T3F2AP-1','Performance Manager','perf@t3f2a.local',true,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES('f7100000-0001-0000-0000-000000000001','section','f7100000-0000-0000-0000-000000000021','staff',true,true);
INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility)
VALUES('f7100000-1000-0000-0000-000000000000','T3F2AP-CURRENT','Performance current','open','normal','f7100000-0001-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000021','private');
INSERT INTO tasks(id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility)
SELECT ('f7100000-2000-0000-0000-' || lpad(g::text,12,'0'))::uuid,
       'T3F2AP-' || lpad(g::text,5,'0'), 'Performance candidate ' || lpad(g::text,5,'0'),
       'open','normal','f7100000-0001-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000021','private'
FROM generate_series(1,10000) g;
ANALYZE tasks;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f7100000-0001-0000-0000-000000000001"}',false);
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM search_tasks_for_dependency('f7100000-1000-0000-0000-000000000000','T3F2AP-000',20);
RESET ROLE;
EXPLAIN (ANALYZE, BUFFERS)
SELECT candidate.id
FROM tasks current_task
JOIN tasks candidate ON candidate.organization_id=current_task.organization_id AND candidate.id<>current_task.id
WHERE current_task.id='f7100000-1000-0000-0000-000000000000'
  AND lower(candidate.task_number) LIKE 't3f2ap-000%'
ORDER BY candidate.task_number,candidate.title,candidate.id
LIMIT 20;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"f7100000-0001-0000-0000-000000000001"}',false);
DO $$ BEGIN IF (SELECT count(*) FROM search_tasks_for_dependency('f7100000-1000-0000-0000-000000000000','T3F2AP-000',20))<>20 THEN RAISE EXCEPTION 'performance result limit failed'; END IF; RAISE NOTICE 'TASK DEPENDENCY CANDIDATE PERFORMANCE: 10000 CANDIDATES, 99 PREFIX MATCHES, LIMIT 20 PASSED'; END $$;
RESET ROLE;

DELETE FROM tasks WHERE id::text LIKE 'f7100000-1000-%' OR id::text LIKE 'f7100000-2000-%';
DELETE FROM user_assignments WHERE user_id='f7100000-0001-0000-0000-000000000001';
DELETE FROM users WHERE id='f7100000-0001-0000-0000-000000000001';
DELETE FROM auth.users WHERE id='f7100000-0001-0000-0000-000000000001';
DELETE FROM sections WHERE id='f7100000-0000-0000-0000-000000000021';
DELETE FROM divisions WHERE id='f7100000-0000-0000-0000-000000000011';
DELETE FROM organizations WHERE id='f7100000-0000-0000-0000-000000000001';
