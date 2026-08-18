-- CorLink — Task search UX authenticated behavioral/RLS suite.
-- Disposable local PostgreSQL only. Creates fixed ea... fixtures and removes them.
-- Covers search_tasks_for_dependency()'s new substring matching and the new
-- search_tasks_for_relationship() RPC. Dependency creation, cycle prevention,
-- and unresolved-prerequisite blocking are unchanged by this patch and are
-- already covered by test-task-dependencies.sql / test-task-dependency-
-- lifecycle-enforcement.sql / test-task-dependency-candidate-management.sql —
-- not duplicated here.
\set ON_ERROR_STOP on

CREATE TEMP TABLE tsl_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON tsl_results TO authenticated;

INSERT INTO organizations (id,name,type,code) VALUES
 ('ea000000-0000-0000-0000-000000000001','TSL Org A','authority','TSLA'),
 ('ea000000-0000-0000-0000-000000000002','TSL Org B','authority','TSLB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('ea000000-0000-0000-0000-000000000011','TSL Division A','ea000000-0000-0000-0000-000000000001'),
 ('ea000000-0000-0000-0000-000000000012','TSL Division X','ea000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('ea000000-0000-0000-0000-000000000021','TSL Section A','TSLSA','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000011'),
 ('ea000000-0000-0000-0000-000000000022','TSL Section X','TSLSX','ea000000-0000-0000-0000-000000000002','ea000000-0000-0000-0000-000000000012');

INSERT INTO auth.users (id,email) VALUES
 ('ea000000-0001-0000-0000-000000000001','manager@tsl.local'),
 ('ea000000-0001-0000-0000-000000000002','viewer-only@tsl.local'),
 ('ea000000-0001-0000-0000-000000000003','cross-org@tsl.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','TSL-1','Manager','manager@tsl.local',true,false),
 ('ea000000-0001-0000-0000-000000000002','ea000000-0000-0000-0000-000000000001','TSL-2','Viewer Only','viewer-only@tsl.local',true,false),
 ('ea000000-0001-0000-0000-000000000003','ea000000-0000-0000-0000-000000000002','TSL-3','Cross Org','cross-org@tsl.local',true,false);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('ea000000-0001-0000-0000-000000000001','section','ea000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('ea000000-0001-0000-0000-000000000002','section','ea000000-0000-0000-0000-000000000021','staff',true,true),
 ('ea000000-0001-0000-0000-000000000003','section','ea000000-0000-0000-0000-000000000022','staff',true,true);

-- current: the task everything is searched from (owned/managed by manager).
-- match-a/match-b: manager-manageable candidates the search should find.
-- unauth: exists, org-scoped organization-visibility so viewer-only can SEE
--   it but not MANAGE it (manager can manage it, so it's a valid dependency/
--   relationship candidate for manager — used as the "manageable" positive
--   case for manager and the "visible but not manageable" negative case for
--   viewer-only).
-- crossorg: same org as manager but different-org task never in scope.
-- alreadydep / alreadyrel: pre-linked to `current`, must be excluded from
--   their respective picker's results.
INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility) VALUES
 ('ea000000-1000-0000-0000-000000000001','TSK-TSLA-2026-0001','Current task','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization'),
 ('ea000000-1000-0000-0000-000000000002','TSK-TSLA-2026-0042','Prepare meeting agenda','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization'),
 ('ea000000-1000-0000-0000-000000000003','TSK-TSLA-2026-0099','Unrelated title entirely','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization'),
 ('ea000000-1000-0000-0000-000000000004','TSK-TSLA-2026-0004','Manager-only manageable','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization'),
 ('ea000000-1000-0000-0000-000000000005','TSK-TSLB-2026-0005','Cross org task','open','normal','ea000000-0001-0000-0000-000000000003','ea000000-0000-0000-0000-000000000002','ea000000-0000-0000-0000-000000000022','organization'),
 ('ea000000-1000-0000-0000-000000000006','TSK-TSLA-2026-0006','Already dependency linked','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization'),
 ('ea000000-1000-0000-0000-000000000007','TSK-TSLA-2026-0007','Already relationship linked','open','normal','ea000000-0001-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000021','organization');

INSERT INTO task_assignments (task_id,user_id,assigned_by,assigned_at,is_active) VALUES
 ('ea000000-1000-0000-0000-000000000002','ea000000-0001-0000-0000-000000000001','ea000000-0001-0000-0000-000000000001',NOW(),true);

INSERT INTO task_dependencies (id,organization_id,dependent_task_id,prerequisite_task_id,created_by) VALUES
 ('ea000000-2000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','ea000000-1000-0000-0000-000000000001','ea000000-1000-0000-0000-000000000006','ea000000-0001-0000-0000-000000000001');
INSERT INTO task_relationships (id,source_task_id,target_task_id,relationship_type,created_by) VALUES
 ('ea000000-3000-0000-0000-000000000001',
  LEAST('ea000000-1000-0000-0000-000000000001','ea000000-1000-0000-0000-000000000007'),
  GREATEST('ea000000-1000-0000-0000-000000000001','ea000000-1000-0000-0000-000000000007'),
  'related','ea000000-0001-0000-0000-000000000001');

DO $outer$
DECLARE
  v_current CONSTANT UUID := 'ea000000-1000-0000-0000-000000000001';
  v_meeting CONSTANT UUID := 'ea000000-1000-0000-0000-000000000002';
  v_manager CONSTANT UUID := 'ea000000-0001-0000-0000-000000000001';
  v_viewer  CONSTANT UUID := 'ea000000-0001-0000-0000-000000000002';
  v_cross   CONSTANT UUID := 'ea000000-0001-0000-0000-000000000003';
  v_n INTEGER;
  v_ids UUID[];
  v_name TEXT;
BEGIN

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- 1. Full task number finds it.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSK-TSLA-2026-0042', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (1, CASE WHEN v_n = 1 THEN 'PASS full task number' ELSE 'FAIL full task number' END);

  -- 2. Partial/substring task number (mid-string, not a prefix) finds it.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, '0042', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (2, CASE WHEN v_n = 1 THEN 'PASS partial task number' ELSE 'FAIL partial task number' END);

  -- 2b. A different substring slice, still not a prefix.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, '2026-0042', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (21, CASE WHEN v_n = 1 THEN 'PASS partial task number (date+seq slice)' ELSE 'FAIL partial task number (date+seq slice)' END);

  -- 3. Full title finds it.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'Prepare meeting agenda', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (3, CASE WHEN v_n = 1 THEN 'PASS full title' ELSE 'FAIL full title' END);

  -- 4. Partial/mid-word title finds it.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'agenda', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (4, CASE WHEN v_n = 1 THEN 'PASS partial title (mid-word)' ELSE 'FAIL partial title (mid-word)' END);

  -- 5. Case-insensitive.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'MEETING', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (5, CASE WHEN v_n = 1 THEN 'PASS case-insensitive' ELSE 'FAIL case-insensitive' END);

  -- 6. Non-matching query returns nothing.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'zzzznonexistent', 20);
  INSERT INTO tsl_results VALUES (6, CASE WHEN v_n = 0 THEN 'PASS non-matching query empty' ELSE 'FAIL non-matching query empty' END);

  -- 6b. Sub-2-character query returns nothing (defense-in-depth guard).
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'T', 20);
  INSERT INTO tsl_results VALUES (61, CASE WHEN v_n = 0 THEN 'PASS 1-char query rejected' ELSE 'FAIL 1-char query rejected' END);

  -- 7. Result limit respected (query matches every TSK-TSLA-2026-* fixture).
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSK-TSLA-2026', 2);
  INSERT INTO tsl_results VALUES (7, CASE WHEN v_n = 2 THEN 'PASS result limit respected' ELSE 'FAIL result limit respected (got ' || v_n || ')' END);

  -- 11. Current task excluded from its own candidate results.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSK-TSLA', 50) WHERE id = v_current;
  INSERT INTO tsl_results VALUES (11, CASE WHEN v_n = 0 THEN 'PASS current task excluded (dependency)' ELSE 'FAIL current task excluded (dependency)' END);

  -- 12. Already-active-prerequisite excluded.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'Already dependency', 20);
  INSERT INTO tsl_results VALUES (12, CASE WHEN v_n = 0 THEN 'PASS existing prerequisite excluded' ELSE 'FAIL existing prerequisite excluded' END);

  -- 8. Unauthorized (visible-but-not-manageable) task never returned, for the
  --    viewer-only persona searching from a task they can view (manager's
  --    v_current has visibility='organization' so viewer can view it) but
  --    cannot manage — search_tasks_for_dependency requires can_manage_task
  --    on the CURRENT task too, so this must return nothing for viewer-only.
  PERFORM set_config('request.jwt.claim.sub', v_viewer::text, true);
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSK-TSLA', 20);
  INSERT INTO tsl_results VALUES (8, CASE WHEN v_n = 0 THEN 'PASS unauthorized (non-manager) search denied' ELSE 'FAIL unauthorized (non-manager) search denied' END);

  -- 9. Cross-org task never returned, even to the org's own manager.
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSL', 50) WHERE id = 'ea000000-1000-0000-0000-000000000005';
  INSERT INTO tsl_results VALUES (9, CASE WHEN v_n = 0 THEN 'PASS cross-org task never returned' ELSE 'FAIL cross-org task never returned' END);

  -- 10. Anonymous caller: empty result, no exception.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'anon', true);
  BEGIN
    SELECT COUNT(*) INTO v_n FROM search_tasks_for_dependency(v_current, 'TSK', 20);
    INSERT INTO tsl_results VALUES (10, CASE WHEN v_n = 0 THEN 'PASS anonymous caller returns empty, no exception' ELSE 'FAIL anonymous caller returns empty, no exception' END);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO tsl_results VALUES (10, 'FAIL anonymous caller raised: ' || SQLERRM);
  END;
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);

  -- ── search_tasks_for_relationship() ──────────────────────────────
  -- 13. Current task excluded.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_relationship(v_current, 'TSK-TSLA', 50) WHERE id = v_current;
  INSERT INTO tsl_results VALUES (13, CASE WHEN v_n = 0 THEN 'PASS current task excluded (relationship)' ELSE 'FAIL current task excluded (relationship)' END);

  -- 14. Already-actively-related task excluded.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_relationship(v_current, 'Already relationship', 20);
  INSERT INTO tsl_results VALUES (14, CASE WHEN v_n = 0 THEN 'PASS existing relationship excluded' ELSE 'FAIL existing relationship excluded' END);

  -- 15. A valid, unrelated, manageable candidate appears.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_relationship(v_current, '0042', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (15, CASE WHEN v_n = 1 THEN 'PASS valid relationship candidate selectable' ELSE 'FAIL valid relationship candidate selectable' END);

  -- 16. Cross-org excluded from relationship search too.
  SELECT COUNT(*) INTO v_n FROM search_tasks_for_relationship(v_current, 'TSL', 50) WHERE id = 'ea000000-1000-0000-0000-000000000005';
  INSERT INTO tsl_results VALUES (16, CASE WHEN v_n = 0 THEN 'PASS cross-org excluded (relationship)' ELSE 'FAIL cross-org excluded (relationship)' END);

  -- 18. assignee_names is populated for a candidate with an active
  --     assignee (single correlated subquery inside the search query
  --     itself, not a separate per-row lookup).
  SELECT assignee_names INTO v_name FROM search_tasks_for_dependency(v_current, '0042', 20) WHERE id = v_meeting;
  INSERT INTO tsl_results VALUES (18, CASE WHEN v_name = 'Manager' THEN 'PASS assignee_names populated' ELSE 'FAIL assignee_names populated (got ' || COALESCE(v_name, 'NULL') || ')' END);

  -- 17. Anonymous denied on the relationship RPC too.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'anon', true);
  BEGIN
    SELECT COUNT(*) INTO v_n FROM search_tasks_for_relationship(v_current, 'TSK', 20);
    INSERT INTO tsl_results VALUES (17, CASE WHEN v_n = 0 THEN 'PASS anonymous denied (relationship)' ELSE 'FAIL anonymous denied (relationship)' END);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO tsl_results VALUES (17, 'FAIL anonymous denied (relationship) raised: ' || SQLERRM);
  END;

END $outer$;

SELECT scenario, name FROM tsl_results ORDER BY scenario;

DO $cleanup$ BEGIN
  DELETE FROM task_relationships WHERE id = 'ea000000-3000-0000-0000-000000000001';
  DELETE FROM task_dependencies WHERE id = 'ea000000-2000-0000-0000-000000000001';
  DELETE FROM tasks WHERE id::text LIKE 'ea000000-1000-%';
  DELETE FROM user_assignments WHERE user_id::text LIKE 'ea000000-0001-%';
  DELETE FROM users WHERE id::text LIKE 'ea000000-0001-%';
  DELETE FROM auth.users WHERE id::text LIKE 'ea000000-0001-%';
  DELETE FROM sections WHERE id::text LIKE 'ea000000-0000-%';
  DELETE FROM divisions WHERE id::text LIKE 'ea000000-0000-%';
  DELETE FROM organizations WHERE id::text LIKE 'ea000000-0000-%';
END $cleanup$;
