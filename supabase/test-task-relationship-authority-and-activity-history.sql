-- CorLink — Task relationship authority + activity history authenticated
-- behavioral suite (docs/114).
-- Disposable local PostgreSQL only. Creates fixed ec... fixtures and
-- removes them at the end. Covers:
--   AUTHORIZATION: can_manage_task_relationship() no longer grants
--     structural add/remove authority merely by active assignment.
--   VALIDATION: self-link/duplicate/cycle prevention, org isolation,
--     and Related/Duplicate/Parent semantics remain unchanged.
--   ACTIVITY: the new record_type='task' relationship-activity rows
--     and their type-aware wording metadata.
-- Relationship candidate search (search_tasks_for_relationship()) and
-- RLS visibility of relationships themselves are unchanged by this
-- patch and already covered by test-task-relationships.sql /
-- test-task-search-and-linking-candidates.sql — not duplicated here.
\set ON_ERROR_STOP on

CREATE TEMP TABLE trh_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON trh_results TO authenticated;

INSERT INTO organizations (id,name,type,code) VALUES
 ('ec000000-0000-0000-0000-000000000001','TRH Org A','authority','TRHA'),
 ('ec000000-0000-0000-0000-000000000002','TRH Org B','authority','TRHB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('ec000000-0000-0000-0000-000000000011','TRH Division A','ec000000-0000-0000-0000-000000000001'),
 ('ec000000-0000-0000-0000-000000000012','TRH Division X','ec000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('ec000000-0000-0000-0000-000000000021','TRH Section A','TRHSA','ec000000-0000-0000-0000-000000000001','ec000000-0000-0000-0000-000000000011'),
 ('ec000000-0000-0000-0000-000000000022','TRH Section B','TRHSB','ec000000-0000-0000-0000-000000000001','ec000000-0000-0000-0000-000000000011'),
 ('ec000000-0000-0000-0000-000000000023','TRH Section X','TRHSX','ec000000-0000-0000-0000-000000000002','ec000000-0000-0000-0000-000000000012');

-- creator: created all tasks, plain 'staff' role -- isolates the
--   "creator" branch of can_manage_task_relationship().
-- supervisor: not the creator, supervises Section A -- isolates the
--   "supervisor-in-scope" branch.
-- assignee: actively assigned to task B, plain 'staff' -- the exact
--   UAT-reported persona.
-- watcher: watches task B, no other standing.
-- unrelated: same org, different section, no relation to task B.
-- cross: different org entirely.
INSERT INTO auth.users (id,email) VALUES
 ('ec000000-0001-0000-0000-000000000001','creator@trh.local'),
 ('ec000000-0001-0000-0000-000000000002','supervisor@trh.local'),
 ('ec000000-0001-0000-0000-000000000003','assignee@trh.local'),
 ('ec000000-0001-0000-0000-000000000004','watcher@trh.local'),
 ('ec000000-0001-0000-0000-000000000005','unrelated@trh.local'),
 ('ec000000-0001-0000-0000-000000000006','cross@trh.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('ec000000-0001-0000-0000-000000000001','ec000000-0000-0000-0000-000000000001','TRH-1','Creator','creator@trh.local',true,false),
 ('ec000000-0001-0000-0000-000000000002','ec000000-0000-0000-0000-000000000001','TRH-2','Supervisor','supervisor@trh.local',true,false),
 ('ec000000-0001-0000-0000-000000000003','ec000000-0000-0000-0000-000000000001','TRH-3','Room manager','assignee@trh.local',true,false),
 ('ec000000-0001-0000-0000-000000000004','ec000000-0000-0000-0000-000000000001','TRH-4','Watcher','watcher@trh.local',true,false),
 ('ec000000-0001-0000-0000-000000000005','ec000000-0000-0000-0000-000000000001','TRH-5','Unrelated Staff','unrelated@trh.local',true,false),
 ('ec000000-0001-0000-0000-000000000006','ec000000-0000-0000-0000-000000000002','TRH-6','Cross Org','cross@trh.local',true,false);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('ec000000-0001-0000-0000-000000000001','section','ec000000-0000-0000-0000-000000000021','staff',true,true),
 ('ec000000-0001-0000-0000-000000000002','section','ec000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('ec000000-0001-0000-0000-000000000003','section','ec000000-0000-0000-0000-000000000021','staff',true,true),
 ('ec000000-0001-0000-0000-000000000004','section','ec000000-0000-0000-0000-000000000021','staff',true,true),
 ('ec000000-0001-0000-0000-000000000005','section','ec000000-0000-0000-0000-000000000022','staff',true,true),
 ('ec000000-0001-0000-0000-000000000006','section','ec000000-0000-0000-0000-000000000023','staff',true,true);

-- taska: general relationship candidate (target of Related/Duplicate).
-- taskb: task with the active assignee/watcher -- the UAT persona.
-- taskcross: different org entirely -- cross-org denial target.
INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility) VALUES
 ('ec000000-1000-0000-0000-000000000001','TSK-TRHA-2026-0001','Task A','open','normal','ec000000-0001-0000-0000-000000000001','ec000000-0000-0000-0000-000000000001','ec000000-0000-0000-0000-000000000021','organization'),
 ('ec000000-1000-0000-0000-000000000002','TSK-TRHA-2026-0002','Task B','open','normal','ec000000-0001-0000-0000-000000000001','ec000000-0000-0000-0000-000000000001','ec000000-0000-0000-0000-000000000021','organization'),
 ('ec000000-1000-0000-0000-000000000003','TSK-TRHB-2026-0003','Cross org task','open','normal','ec000000-0001-0000-0000-000000000006','ec000000-0000-0000-0000-000000000002','ec000000-0000-0000-0000-000000000023','organization');

INSERT INTO task_assignments (task_id,user_id,assigned_by,assigned_at,is_active) VALUES
 ('ec000000-1000-0000-0000-000000000002','ec000000-0001-0000-0000-000000000003','ec000000-0001-0000-0000-000000000001',NOW(),true);
INSERT INTO task_watchers (task_id,user_id) VALUES
 ('ec000000-1000-0000-0000-000000000002','ec000000-0001-0000-0000-000000000004');

DO $outer$
DECLARE
  v_taska CONSTANT UUID := 'ec000000-1000-0000-0000-000000000001';
  v_taskb CONSTANT UUID := 'ec000000-1000-0000-0000-000000000002';
  v_taskcross CONSTANT UUID := 'ec000000-1000-0000-0000-000000000003';
  v_creator    CONSTANT UUID := 'ec000000-0001-0000-0000-000000000001';
  v_supervisor CONSTANT UUID := 'ec000000-0001-0000-0000-000000000002';
  v_assignee   CONSTANT UUID := 'ec000000-0001-0000-0000-000000000003';
  v_watcher    CONSTANT UUID := 'ec000000-0001-0000-0000-000000000004';
  v_unrelated  CONSTANT UUID := 'ec000000-0001-0000-0000-000000000005';
  v_cross      CONSTANT UUID := 'ec000000-0001-0000-0000-000000000006';
  v_n INTEGER;
  v_ok BOOLEAN;
  v_rel_id UUID;
  v_task_c UUID;
  v_task_d UUID;
  v_task_e UUID;
  v_action TEXT;
  v_notes TEXT;
  v_cap RECORD;
BEGIN

  -- ── AUTHORIZATION ─────────────────────────────────────────────

  -- 1. Creator (manage-tier via created_by) can add a Related relationship.
  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  PERFORM set_config('role', 'authenticated', true);
  SELECT create_task('ec000000-0000-0000-0000-000000000001','Draft task C',NULL,'ec000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_c;
  v_ok := TRUE;
  BEGIN
    v_rel_id := create_task_relationship(v_task_c, v_taska, 'related');
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO trh_results VALUES (1, CASE WHEN v_ok THEN 'PASS creator can add Related relationship' ELSE 'FAIL creator can add Related relationship' END);

  -- 2. Creator can remove it.
  v_ok := TRUE;
  BEGIN
    PERFORM remove_task_relationship(v_rel_id, v_task_c);
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO trh_results VALUES (2, CASE WHEN v_ok THEN 'PASS creator can remove relationship' ELSE 'FAIL creator can remove relationship' END);

  -- 9a. Supervisor-in-scope (not creator) can add and remove too --
  --     "both-side authority preserved": supervisor must manage BOTH
  --     endpoints, and here supervises the section both tasks live in.
  PERFORM set_config('request.jwt.claim.sub', v_supervisor::text, true);
  v_ok := TRUE;
  BEGIN
    v_rel_id := create_task_relationship(v_task_c, v_taska, 'related');
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO trh_results VALUES (91, CASE WHEN v_ok THEN 'PASS supervisor-in-scope can add relationship' ELSE 'FAIL supervisor-in-scope can add relationship' END);
  v_ok := TRUE;
  BEGIN
    PERFORM remove_task_relationship(v_rel_id, v_task_c);
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO trh_results VALUES (92, CASE WHEN v_ok THEN 'PASS supervisor-in-scope can remove relationship' ELSE 'FAIL supervisor-in-scope can remove relationship' END);

  -- Re-create the relationship as creator for the assignee/watcher
  -- denial tests below.
  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  v_rel_id := create_task_relationship(v_taskb, v_taska, 'related');

  -- 3. Assignee (active assignee of task B, no other standing) cannot add.
  PERFORM set_config('request.jwt.claim.sub', v_assignee::text, true);
  SELECT create_task('ec000000-0000-0000-0000-000000000001','Draft task D',NULL,'ec000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_d;
  -- (created as assignee itself is fine -- create_task() has no
  -- manage-tier gate -- but ownership doesn't matter for this check.)
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_task_d, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (3, CASE WHEN NOT v_ok THEN 'PASS assignee cannot add relationship' ELSE 'FAIL assignee cannot add relationship' END);

  -- 4. Assignee cannot remove the real, pre-existing relationship on task B.
  v_ok := FALSE;
  BEGIN
    PERFORM remove_task_relationship(v_rel_id, v_taskb);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (4, CASE WHEN NOT v_ok THEN 'PASS assignee cannot remove relationship' ELSE 'FAIL assignee cannot remove relationship' END);

  -- get_task_relationship_capabilities() / list_related_tasks() agree
  -- with the RPC-level denial above.
  SELECT * INTO v_cap FROM get_task_relationship_capabilities(v_taskb);
  INSERT INTO trh_results VALUES (93, CASE WHEN NOT v_cap.can_create AND NOT v_cap.can_remove
    THEN 'PASS assignee capabilities: create/remove both false' ELSE 'FAIL assignee capabilities' END);
  SELECT can_remove INTO v_ok FROM list_related_tasks(v_taskb) WHERE relationship_id = v_rel_id;
  INSERT INTO trh_results VALUES (94, CASE WHEN v_ok = FALSE THEN 'PASS assignee row can_remove is false' ELSE 'FAIL assignee row can_remove' END);

  -- 5. Watcher (no other standing) cannot add or remove.
  PERFORM set_config('request.jwt.claim.sub', v_watcher::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_task_d, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    PERFORM remove_task_relationship(v_rel_id, v_taskb);
    v_ok := v_ok OR TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (5, CASE WHEN NOT v_ok THEN 'PASS watcher cannot add/remove' ELSE 'FAIL watcher cannot add/remove' END);

  -- 6. Unrelated same-org user denied.
  PERFORM set_config('request.jwt.claim.sub', v_unrelated::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_task_d, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (6, CASE WHEN NOT v_ok THEN 'PASS unrelated same-org user denied' ELSE 'FAIL unrelated same-org user denied' END);

  -- 7. Cross-org user denied (both a direct attempt, and org isolation
  --    on a cross-org target).
  PERFORM set_config('request.jwt.claim.sub', v_cross::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_task_d, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (7, CASE WHEN NOT v_ok THEN 'PASS cross-org user denied' ELSE 'FAIL cross-org user denied' END);

  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_taskcross, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (95, CASE WHEN NOT v_ok THEN 'PASS cross-org target rejected (organization isolation)' ELSE 'FAIL cross-org target rejected' END);

  -- 8. Anonymous (no claims) denied.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'anon', true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_task_d, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (8, CASE WHEN NOT v_ok THEN 'PASS anonymous denied' ELSE 'FAIL anonymous denied' END);

  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- ── VALIDATION (unchanged logic; regression) ─────────────────────

  -- 10. Self-link remains rejected.
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_taskb, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (10, CASE WHEN NOT v_ok THEN 'PASS self-link rejected' ELSE 'FAIL self-link rejected' END);

  -- 11. Duplicate relationship remains rejected (taskb<->taska already
  --     exists from the setup above).
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taskb, v_taska, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (11, CASE WHEN NOT v_ok THEN 'PASS duplicate relationship rejected' ELSE 'FAIL duplicate relationship rejected' END);
  -- ...including the reverse pair (same tasks, order swapped).
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_taska, v_taskb, 'related');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (96, CASE WHEN NOT v_ok THEN 'PASS reverse-pair duplicate rejected' ELSE 'FAIL reverse-pair duplicate rejected' END);

  -- 13. Parent direction remains correct: taskc becomes the parent of
  --     taskd (source=parent, target=child, unchanged direction rule).
  v_rel_id := create_task_relationship(v_task_c, v_task_d, 'parent');
  SELECT (relationship_type = 'parent') INTO v_ok FROM list_related_tasks(v_task_c) WHERE relationship_id = v_rel_id;
  INSERT INTO trh_results VALUES (13, CASE WHEN v_ok THEN 'PASS parent direction correct (viewed from parent side)' ELSE 'FAIL parent direction (parent side)' END);
  SELECT (relationship_type = 'child') INTO v_ok FROM list_related_tasks(v_task_d) WHERE relationship_id = v_rel_id;
  INSERT INTO trh_results VALUES (97, CASE WHEN v_ok THEN 'PASS parent direction correct (viewed from child side)' ELSE 'FAIL parent direction (child side)' END);

  -- 12. Cycle prevention remains intact: taskd is already a child of
  --     taskc; making taskc a child of taskd would be circular.
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_relationship(v_task_d, v_task_c, 'parent');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO trh_results VALUES (12, CASE WHEN NOT v_ok THEN 'PASS parent cycle prevention remains intact' ELSE 'FAIL parent cycle prevention' END);

  -- 14/15. Duplicate and Related semantics remain correct (symmetric,
  --        canonicalized storage order, no direction flip on read).
  SELECT create_task('ec000000-0000-0000-0000-000000000001','Draft task E',NULL,'ec000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_e;
  v_rel_id := create_task_relationship(v_task_e, v_taska, 'duplicate');
  SELECT (relationship_type = 'duplicate') INTO v_ok FROM list_related_tasks(v_task_e) WHERE relationship_id = v_rel_id;
  INSERT INTO trh_results VALUES (14, CASE WHEN v_ok THEN 'PASS Duplicate semantics correct' ELSE 'FAIL Duplicate semantics' END);
  SELECT (relationship_type = 'duplicate') INTO v_ok FROM list_related_tasks(v_taska) WHERE relationship_id = v_rel_id;
  INSERT INTO trh_results VALUES (98, CASE WHEN v_ok THEN 'PASS Duplicate semantics symmetric (no flip on either side)' ELSE 'FAIL Duplicate symmetry' END);
  PERFORM remove_task_relationship(v_rel_id, v_task_e);

  SELECT (relationship_type = 'related') INTO v_ok FROM list_related_tasks(v_taskb) WHERE related_task_id = v_taska;
  INSERT INTO trh_results VALUES (15, CASE WHEN v_ok THEN 'PASS Related semantics correct' ELSE 'FAIL Related semantics' END);

  -- ── ACTIVITY ──────────────────────────────────────────────────

  -- 16/18/21. Relationship add creates a task-timeline Activity event
  --           with Related wording metadata and the related task's
  --           bare id stored structurally (not its title/number).
  v_rel_id := create_task_relationship(v_task_e, v_taska, 'related');
  SELECT action, notes INTO v_action, v_notes FROM audit_logs
    WHERE record_type = 'task' AND record_id = v_task_e AND action = 'task_relationship_added'
    ORDER BY created_at DESC LIMIT 1;
  INSERT INTO trh_results VALUES (16, CASE WHEN v_action = 'task_relationship_added' THEN 'PASS relationship add creates Activity event' ELSE 'FAIL relationship add Activity event' END);
  INSERT INTO trh_results VALUES (18, CASE WHEN v_notes = 'related_task_id=' || v_taska::text || ';relationship_type=related'
    THEN 'PASS Related wording metadata correct' ELSE 'FAIL Related wording metadata: ' || COALESCE(v_notes,'NULL') END);
  INSERT INTO trh_results VALUES (21, CASE WHEN v_notes LIKE 'related_task_id=' || v_taska::text || '%' AND v_notes NOT LIKE '%' || (SELECT title FROM tasks WHERE id = v_taska) || '%'
    THEN 'PASS related-task id stored structurally (no title/number baked in)' ELSE 'FAIL structural id storage' END);

  -- 17. Relationship remove creates a task-timeline Activity event.
  PERFORM remove_task_relationship(v_rel_id, v_task_e);
  SELECT action, notes INTO v_action, v_notes FROM audit_logs
    WHERE record_type = 'task' AND record_id = v_task_e AND action = 'task_relationship_removed'
    ORDER BY created_at DESC LIMIT 1;
  INSERT INTO trh_results VALUES (17, CASE WHEN v_action = 'task_relationship_removed' AND v_notes = 'related_task_id=' || v_taska::text
    THEN 'PASS relationship remove creates Activity event' ELSE 'FAIL relationship remove Activity event' END);

  -- 19. Duplicate wording metadata correct.
  v_rel_id := create_task_relationship(v_task_e, v_taska, 'duplicate');
  SELECT notes INTO v_notes FROM audit_logs
    WHERE record_type = 'task' AND record_id = v_task_e AND action = 'task_relationship_added'
    ORDER BY created_at DESC LIMIT 1;
  INSERT INTO trh_results VALUES (19, CASE WHEN v_notes = 'related_task_id=' || v_taska::text || ';relationship_type=duplicate'
    THEN 'PASS Duplicate wording metadata correct' ELSE 'FAIL Duplicate wording metadata: ' || COALESCE(v_notes,'NULL') END);
  PERFORM remove_task_relationship(v_rel_id, v_task_e);

  -- 20. Parent wording metadata correct: viewer (source=task_e) is the
  --     parent, so the OTHER task's (task_d... already a child of
  --     task_c; use a fresh pair) role recorded is 'child'.
  DELETE FROM task_relationships WHERE (source_task_id = v_task_c AND target_task_id = v_task_d) OR (source_task_id = v_task_d AND target_task_id = v_task_c);
  v_rel_id := create_task_relationship(v_task_e, v_task_d, 'parent');
  SELECT notes INTO v_notes FROM audit_logs
    WHERE record_type = 'task' AND record_id = v_task_e AND action = 'task_relationship_added'
    ORDER BY created_at DESC LIMIT 1;
  INSERT INTO trh_results VALUES (20, CASE WHEN v_notes = 'related_task_id=' || v_task_d::text || ';relationship_type=child'
    THEN 'PASS Parent wording metadata correct (viewer=parent, other recorded as child)' ELSE 'FAIL Parent wording metadata: ' || COALESCE(v_notes,'NULL') END);

  -- 22. Unauthorized viewer does not receive related-task metadata
  --     leakage: the audit row's notes never contain the related
  --     task's title/number regardless of who reads it (title/number
  --     resolution happens client-side through RLS-filtered `tasks`,
  --     not from stored notes) -- already exercised by #21 above; here
  --     confirm the record_type='task' row itself is invisible to an
  --     unrelated viewer (RLS), same path every other 'task' audit row
  --     uses.
  PERFORM set_config('request.jwt.claim.sub', v_unrelated::text, true);
  SELECT count(*) INTO v_n FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_e AND action = 'task_relationship_added';
  INSERT INTO trh_results VALUES (22, CASE WHEN v_n = 0 THEN 'PASS unauthorized viewer cannot see the relationship-activity row at all' ELSE 'FAIL unauthorized viewer leak' END);
  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);

  RESET role;
END $outer$;

SELECT scenario, name FROM trh_results ORDER BY scenario;

DO $cleanup$ BEGIN
  DELETE FROM audit_logs WHERE record_id::text LIKE 'ec000000-%';
  DELETE FROM task_relationships WHERE source_task_id::text LIKE 'ec000000-%' OR target_task_id::text LIKE 'ec000000-%';
  DELETE FROM task_watchers WHERE task_id::text LIKE 'ec000000-%';
  DELETE FROM task_assignments WHERE task_id::text LIKE 'ec000000-%';
  DELETE FROM tasks WHERE id::text LIKE 'ec000000-%';
  DELETE FROM user_assignments WHERE user_id::text LIKE 'ec000000-0001-%';
  DELETE FROM users WHERE id::text LIKE 'ec000000-0001-%';
  DELETE FROM auth.users WHERE id::text LIKE 'ec000000-0001-%';
  DELETE FROM sections WHERE id::text LIKE 'ec000000-0000-%';
  DELETE FROM divisions WHERE id::text LIKE 'ec000000-0000-%';
  DELETE FROM organizations WHERE id::text LIKE 'ec000000-0000-%';
END $cleanup$;
