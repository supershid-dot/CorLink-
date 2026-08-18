-- CorLink — Task dependency authority + activity history authenticated
-- behavioral suite (docs/113).
-- Disposable local PostgreSQL only. Creates fixed eb... fixtures and
-- removes them at the end. Covers:
--   DEPENDENCY AUTHORITY: can_manage_task_dependency() no longer grants
--     structural add/remove authority merely by active assignment.
--   ACTIVITY: update_task() lifecycle-transition action codes, the new
--     record_type='task' dependency-activity rows, and assign_task()/
--     unassign_task()'s named notes.
-- Dependency candidate search, RLS visibility of dependencies
-- themselves, and complete_task()/cancel_task()'s own authorization
-- are unchanged by this patch and already covered by test-task-
-- dependencies.sql / test-task-dependency-lifecycle-enforcement.sql /
-- test-task-search-and-linking-candidates.sql — not duplicated here.
\set ON_ERROR_STOP on

CREATE TEMP TABLE tdh_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON tdh_results TO authenticated;

INSERT INTO organizations (id,name,type,code) VALUES
 ('eb000000-0000-0000-0000-000000000001','TDH Org A','authority','TDHA'),
 ('eb000000-0000-0000-0000-000000000002','TDH Org B','authority','TDHB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('eb000000-0000-0000-0000-000000000011','TDH Division A','eb000000-0000-0000-0000-000000000001'),
 ('eb000000-0000-0000-0000-000000000012','TDH Division X','eb000000-0000-0000-0000-000000000002');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('eb000000-0000-0000-0000-000000000021','TDH Section A','TDHSA','eb000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000011'),
 ('eb000000-0000-0000-0000-000000000022','TDH Section B','TDHSB','eb000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000011'),
 ('eb000000-0000-0000-0000-000000000023','TDH Section X','TDHSX','eb000000-0000-0000-0000-000000000002','eb000000-0000-0000-0000-000000000012');

-- creator: created both tasks, plain 'staff' role (no supervisor standing) —
--   isolates the "creator" branch of can_manage_task_dependency().
-- supervisor: not the creator, supervises Section A — isolates the
--   "supervisor-in-scope" branch.
-- assignee: actively assigned to task B, plain 'staff', not creator/
--   supervisor — the exact UAT-reported persona.
-- watcher: watches task B, no other standing.
-- unrelated: same org, different section, no relation to task B.
-- cross: different org entirely.
INSERT INTO auth.users (id,email) VALUES
 ('eb000000-0001-0000-0000-000000000001','creator@tdh.local'),
 ('eb000000-0001-0000-0000-000000000002','supervisor@tdh.local'),
 ('eb000000-0001-0000-0000-000000000003','assignee@tdh.local'),
 ('eb000000-0001-0000-0000-000000000004','watcher@tdh.local'),
 ('eb000000-0001-0000-0000-000000000005','unrelated@tdh.local'),
 ('eb000000-0001-0000-0000-000000000006','cross@tdh.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('eb000000-0001-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001','TDH-1','Creator','creator@tdh.local',true,false),
 ('eb000000-0001-0000-0000-000000000002','eb000000-0000-0000-0000-000000000001','TDH-2','Supervisor','supervisor@tdh.local',true,false),
 ('eb000000-0001-0000-0000-000000000003','eb000000-0000-0000-0000-000000000001','TDH-3','Room manager','assignee@tdh.local',true,false),
 ('eb000000-0001-0000-0000-000000000004','eb000000-0000-0000-0000-000000000001','TDH-4','Watcher','watcher@tdh.local',true,false),
 ('eb000000-0001-0000-0000-000000000005','eb000000-0000-0000-0000-000000000001','TDH-5','Unrelated Staff','unrelated@tdh.local',true,false),
 ('eb000000-0001-0000-0000-000000000006','eb000000-0000-0000-0000-000000000002','TDH-6','Cross Org','cross@tdh.local',true,false);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('eb000000-0001-0000-0000-000000000001','section','eb000000-0000-0000-0000-000000000021','staff',true,true),
 ('eb000000-0001-0000-0000-000000000002','section','eb000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('eb000000-0001-0000-0000-000000000003','section','eb000000-0000-0000-0000-000000000021','staff',true,true),
 ('eb000000-0001-0000-0000-000000000004','section','eb000000-0000-0000-0000-000000000021','staff',true,true),
 ('eb000000-0001-0000-0000-000000000005','section','eb000000-0000-0000-0000-000000000022','staff',true,true),
 ('eb000000-0001-0000-0000-000000000006','section','eb000000-0000-0000-0000-000000000023','staff',true,true);

-- taska: prerequisite candidate, open, unresolved.
-- taskb: dependent task, open, assignee actively assigned, watcher watching.
-- alreadydep_prereq: pre-linked to taskb (taskb depends on it) for the
--   assignee/watcher remove-denial tests.
INSERT INTO tasks (id,task_number,title,status,priority,created_by,organization_id,owning_section_id,visibility) VALUES
 ('eb000000-1000-0000-0000-000000000001','TSK-TDHA-2026-0001','Task A','open','normal','eb000000-0001-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000021','organization'),
 ('eb000000-1000-0000-0000-000000000002','TSK-TDHA-2026-0002','Task B','open','normal','eb000000-0001-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000021','organization'),
 ('eb000000-1000-0000-0000-000000000003','TSK-TDHA-2026-0003','Already linked prerequisite','open','normal','eb000000-0001-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000021','organization');

INSERT INTO task_assignments (task_id,user_id,assigned_by,assigned_at,is_active) VALUES
 ('eb000000-1000-0000-0000-000000000002','eb000000-0001-0000-0000-000000000003','eb000000-0001-0000-0000-000000000001',NOW(),true);
INSERT INTO task_watchers (task_id,user_id) VALUES
 ('eb000000-1000-0000-0000-000000000002','eb000000-0001-0000-0000-000000000004');
INSERT INTO task_dependencies (id,organization_id,dependent_task_id,prerequisite_task_id,created_by) VALUES
 ('eb000000-2000-0000-0000-000000000001','eb000000-0000-0000-0000-000000000001','eb000000-1000-0000-0000-000000000002','eb000000-1000-0000-0000-000000000003','eb000000-0001-0000-0000-000000000001');

DO $outer$
DECLARE
  v_taska CONSTANT UUID := 'eb000000-1000-0000-0000-000000000001';
  v_taskb CONSTANT UUID := 'eb000000-1000-0000-0000-000000000002';
  v_alreadydep_prereq CONSTANT UUID := 'eb000000-1000-0000-0000-000000000003';
  v_alreadydep CONSTANT UUID := 'eb000000-2000-0000-0000-000000000001';
  v_creator    CONSTANT UUID := 'eb000000-0001-0000-0000-000000000001';
  v_supervisor CONSTANT UUID := 'eb000000-0001-0000-0000-000000000002';
  v_assignee   CONSTANT UUID := 'eb000000-0001-0000-0000-000000000003';
  v_watcher    CONSTANT UUID := 'eb000000-0001-0000-0000-000000000004';
  v_unrelated  CONSTANT UUID := 'eb000000-0001-0000-0000-000000000005';
  v_cross      CONSTANT UUID := 'eb000000-0001-0000-0000-000000000006';
  v_n INTEGER;
  v_ok BOOLEAN;
  v_cap RECORD;
  v_new_dep UUID;
  v_task_f UUID;
  v_task_g UUID;
  v_task_e UUID;
  v_action TEXT;
  v_notes TEXT;
BEGIN

  -- ── DEPENDENCY AUTHORITY ──────────────────────────────────────

  -- 1. Creator (manage-tier via created_by) can add a prerequisite.
  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  PERFORM set_config('role', 'authenticated', true);
  SELECT create_task('eb000000-0000-0000-0000-000000000001','Draft task F',NULL,'eb000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_f;
  v_ok := TRUE;
  BEGIN
    PERFORM create_task_dependency(v_task_f, v_taska);
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO tdh_results VALUES (1, CASE WHEN v_ok THEN 'PASS creator can add prerequisite' ELSE 'FAIL creator can add prerequisite' END);

  -- 2. Creator can remove that prerequisite.
  SELECT id INTO v_new_dep FROM task_dependencies WHERE dependent_task_id = v_task_f AND prerequisite_task_id = v_taska AND removed_at IS NULL;
  v_ok := TRUE;
  BEGIN
    PERFORM remove_task_dependency(v_new_dep);
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO tdh_results VALUES (2, CASE WHEN v_ok THEN 'PASS creator can remove prerequisite' ELSE 'FAIL creator can remove prerequisite' END);

  -- 3. Assignee (active assignee of task B, no other standing) cannot add.
  PERFORM set_config('request.jwt.claim.sub', v_assignee::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taskb, v_taska);
    v_ok := TRUE; -- unexpectedly succeeded
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (3, CASE WHEN NOT v_ok THEN 'PASS assignee cannot add prerequisite' ELSE 'FAIL assignee cannot add prerequisite' END);

  -- 4. Assignee cannot remove the pre-existing dependency on task B.
  v_ok := FALSE;
  BEGIN
    PERFORM remove_task_dependency(v_alreadydep);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (4, CASE WHEN NOT v_ok THEN 'PASS assignee cannot remove prerequisite' ELSE 'FAIL assignee cannot remove prerequisite' END);

  -- get_task_dependency_capabilities() / list_task_dependencies() agree
  -- with the RPC-level denial above (frontend gates its buttons on
  -- exactly these two reads).
  SELECT * INTO v_cap FROM get_task_dependency_capabilities(v_taskb);
  INSERT INTO tdh_results VALUES (21, CASE WHEN v_cap.can_view_dependencies AND NOT v_cap.can_add_dependency AND NOT v_cap.can_remove_dependency
    THEN 'PASS assignee capabilities: view yes, add/remove no' ELSE 'FAIL assignee capabilities' END);
  SELECT can_remove INTO v_ok FROM list_task_dependencies(v_taskb) WHERE dependency_id = v_alreadydep;
  INSERT INTO tdh_results VALUES (22, CASE WHEN v_ok = FALSE THEN 'PASS assignee row can_remove is false' ELSE 'FAIL assignee row can_remove' END);

  -- 5. Watcher (no other standing) cannot add or remove.
  PERFORM set_config('request.jwt.claim.sub', v_watcher::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taskb, v_taska);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    PERFORM remove_task_dependency(v_alreadydep);
    v_ok := v_ok OR TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (5, CASE WHEN NOT v_ok THEN 'PASS watcher cannot add/remove' ELSE 'FAIL watcher cannot add/remove' END);

  -- 6. Unrelated same-org user denied.
  PERFORM set_config('request.jwt.claim.sub', v_unrelated::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taskb, v_taska);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (6, CASE WHEN NOT v_ok THEN 'PASS unrelated same-org user denied' ELSE 'FAIL unrelated same-org user denied' END);

  -- 7. Cross-org user denied.
  PERFORM set_config('request.jwt.claim.sub', v_cross::text, true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taskb, v_taska);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (7, CASE WHEN NOT v_ok THEN 'PASS cross-org user denied' ELSE 'FAIL cross-org user denied' END);

  -- 8. Anonymous (no claims) denied.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'anon', true);
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taskb, v_taska);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (8, CASE WHEN NOT v_ok THEN 'PASS anonymous denied' ELSE 'FAIL anonymous denied' END);

  -- ── DEPENDENCY LIFECYCLE PRESERVATION (unchanged logic; regression) ──
  PERFORM set_config('request.jwt.claim.sub', v_creator::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- 9. Start Work stays blocked while task A (taskb's prerequisite via
  --    a fresh dependency) is unresolved.
  PERFORM create_task_dependency(v_taskb, v_taska);
  v_ok := FALSE;
  BEGIN
    PERFORM update_task(v_taskb, NULL,NULL,NULL,NULL,NULL,NULL,NULL,'in_progress');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (9, CASE WHEN NOT v_ok THEN 'PASS Start Work blocked while prerequisite unresolved' ELSE 'FAIL Start Work blocked while prerequisite unresolved' END);

  -- 11. Cycle prevention remains intact (checked BEFORE either task is
  --     completed below, so a rejection here can only come from actual
  --     cycle/reverse-pair detection, never the separate "prerequisite
  --     endpoints must be draft/open/waiting" status guard): taskb
  --     already depends on taska (just created above); the exact
  --     reverse (taska depends on taskb) must still be rejected.
  v_ok := FALSE;
  BEGIN
    PERFORM create_task_dependency(v_taska, v_taskb);
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO tdh_results VALUES (11, CASE WHEN NOT v_ok THEN 'PASS cycle prevention remains intact' ELSE 'FAIL cycle prevention remains intact' END);

  -- 10. ...and Start Work succeeds once every active prerequisite is
  --     resolved. This same call also covers #15 (task_work_started
  --     wording).
  PERFORM complete_task(v_taska);
  PERFORM complete_task(v_alreadydep_prereq);
  v_ok := TRUE;
  BEGIN
    PERFORM update_task(v_taskb, NULL,NULL,NULL,NULL,NULL,NULL,NULL,'in_progress');
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  INSERT INTO tdh_results VALUES (10, CASE WHEN v_ok THEN 'PASS Start Work succeeds once resolved' ELSE 'FAIL Start Work succeeds once resolved' END);

  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_taskb ORDER BY created_at DESC, id DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (15, CASE WHEN v_action = 'task_work_started' THEN 'PASS Open->In Progress emits task_work_started' ELSE 'FAIL Open->In Progress emits ' || COALESCE(v_action, 'NULL') END);

  -- ── ACTIVITY ──────────────────────────────────────────────────

  -- 12. Creation emits a clear, unchanged 'created' action.
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_f AND action = 'created';
  INSERT INTO tdh_results VALUES (12, CASE WHEN v_action = 'created' THEN 'PASS create emits created' ELSE 'FAIL create emits created' END);

  -- 13. Assignment names the assignee (not a raw UUID).
  PERFORM assign_task(v_task_f, v_assignee);
  SELECT notes INTO v_notes FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_f AND action = 'assigned' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (13, CASE WHEN v_notes = 'Room manager' THEN 'PASS assignment names the assignee' ELSE 'FAIL assignment notes: ' || COALESCE(v_notes, 'NULL') END);

  -- Unassignment also names the (former) assignee.
  PERFORM unassign_task(v_task_f, v_assignee);
  SELECT notes INTO v_notes FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_f AND action = 'unassigned' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (23, CASE WHEN v_notes = 'Room manager' THEN 'PASS unassignment names the (former) assignee' ELSE 'FAIL unassignment notes: ' || COALESCE(v_notes, 'NULL') END);

  -- 14. Draft -> Open emits the distinct task_started action.
  SELECT create_task('eb000000-0000-0000-0000-000000000001','Draft task E',NULL,'eb000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_e;
  PERFORM update_task(v_task_e, NULL,NULL,NULL,NULL,NULL,NULL,NULL,'open');
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_e ORDER BY created_at DESC, id DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (14, CASE WHEN v_action = 'task_started' THEN 'PASS Draft->Open emits task_started' ELSE 'FAIL Draft->Open emits ' || COALESCE(v_action, 'NULL') END);

  -- 16. Completion emits the distinct, unchanged 'completed' action.
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_taska AND action = 'completed';
  INSERT INTO tdh_results VALUES (16, CASE WHEN v_action = 'completed' THEN 'PASS completion emits completed' ELSE 'FAIL completion emits completed' END);

  -- 17/18. Dependency add/remove now ALSO write a record_type='task' row
  --        against the dependent task (previously invisible on its own
  --        Activity timeline — see this patch's header comment), with
  --        only the related task's bare id in notes.
  SELECT create_task('eb000000-0000-0000-0000-000000000001','Draft task G',NULL,'eb000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_g;
  PERFORM create_task_dependency(v_task_g, v_taska);
  SELECT action, notes INTO v_action, v_notes FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_g AND action = 'task_dependency_added' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (17, CASE WHEN v_action = 'task_dependency_added' AND v_notes = 'related_task_id=' || v_taska::text
    THEN 'PASS dependency add visible on dependent task timeline' ELSE 'FAIL dependency add timeline row' END);

  SELECT id INTO v_new_dep FROM task_dependencies WHERE dependent_task_id = v_task_g AND prerequisite_task_id = v_taska AND removed_at IS NULL;
  PERFORM remove_task_dependency(v_new_dep);
  SELECT action, notes INTO v_action, v_notes FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_g AND action = 'task_dependency_removed' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (18, CASE WHEN v_action = 'task_dependency_removed' AND v_notes = 'related_task_id=' || v_taska::text
    THEN 'PASS dependency remove visible on dependent task timeline' ELSE 'FAIL dependency remove timeline row' END);

  -- 19. Cancellation remains distinct and unchanged.
  PERFORM cancel_task(v_task_g, 'no longer needed');
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_g AND action = 'cancelled';
  INSERT INTO tdh_results VALUES (19, CASE WHEN v_action = 'cancelled' THEN 'PASS cancellation emits cancelled' ELSE 'FAIL cancellation emits cancelled' END);

  -- 20. A details-only edit (no lifecycle transition) still falls back
  --     safely to the generic 'edited' action — confirms the new
  --     transition detection is precisely scoped and does not
  --     misclassify an ordinary edit.
  PERFORM update_task(v_task_e, NULL,NULL,'high',NULL,NULL,NULL,NULL,NULL);
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_e ORDER BY created_at DESC, id DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (20, CASE WHEN v_action = 'edited' THEN 'PASS details-only edit still falls back to edited' ELSE 'FAIL details-only edit emitted ' || COALESCE(v_action, 'NULL') END);

  -- 24. The exact live UAT reproduction: a plain active assignee (no
  --     manage-tier standing at all) performs a pure Start Work call
  --     — update_task()'s v_is_pure_start_request exception, the only
  --     path a bare assignee can call update_task() through at all —
  --     and the activity trail records task_work_started, not the
  --     generic 'edited' the original bug report showed.
  SELECT create_task('eb000000-0000-0000-0000-000000000001','Draft task H',NULL,'eb000000-0000-0000-0000-000000000021','normal','organization',NULL,NULL) INTO v_task_g;
  PERFORM update_task(v_task_g, NULL,NULL,NULL,NULL,NULL,NULL,NULL,'open');
  PERFORM assign_task(v_task_g, v_assignee);
  PERFORM set_config('request.jwt.claim.sub', v_assignee::text, true);
  v_ok := TRUE;
  BEGIN
    PERFORM update_task(v_task_g, NULL,NULL,NULL,NULL,NULL,NULL,NULL,'in_progress');
  EXCEPTION WHEN OTHERS THEN v_ok := FALSE;
  END;
  SELECT action INTO v_action FROM audit_logs WHERE record_type = 'task' AND record_id = v_task_g ORDER BY created_at DESC, id DESC LIMIT 1;
  INSERT INTO tdh_results VALUES (24, CASE WHEN v_ok AND v_action = 'task_work_started'
    THEN 'PASS assignee pure Start Work call succeeds and emits task_work_started' ELSE 'FAIL assignee Start Work: ok=' || v_ok || ' action=' || COALESCE(v_action, 'NULL') END);

  RESET role;
END $outer$;

SELECT scenario, name FROM tdh_results ORDER BY scenario;

DO $cleanup$ BEGIN
  DELETE FROM audit_logs WHERE record_id::text LIKE 'eb000000-%';
  DELETE FROM task_dependencies WHERE organization_id::text LIKE 'eb000000-%' OR dependent_task_id::text LIKE 'eb000000-%';
  DELETE FROM task_watchers WHERE task_id::text LIKE 'eb000000-%';
  DELETE FROM task_assignments WHERE task_id::text LIKE 'eb000000-%';
  DELETE FROM tasks WHERE id::text LIKE 'eb000000-%';
  DELETE FROM user_assignments WHERE user_id::text LIKE 'eb000000-0001-%';
  DELETE FROM users WHERE id::text LIKE 'eb000000-0001-%';
  DELETE FROM auth.users WHERE id::text LIKE 'eb000000-0001-%';
  DELETE FROM sections WHERE id::text LIKE 'eb000000-0000-%';
  DELETE FROM divisions WHERE id::text LIKE 'eb000000-0000-%';
  DELETE FROM organizations WHERE id::text LIKE 'eb000000-0000-%';
END $cleanup$;
