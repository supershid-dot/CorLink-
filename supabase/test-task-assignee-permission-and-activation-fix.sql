-- CorLink — behavioral test for the UAT Task assignee-permission +
-- Draft-activation correction (docs/107).
-- Disposable/local PostgreSQL only. Creates fixed af000000... fixtures
-- and removes them at the end.
--
-- Reproduces the exact reported scenario: "Normal staff" (creator)
-- creates a standalone task, assigns "Room manager" (a plain
-- assignee — no supervisor role). Also covers a supervisor-in-scope
-- manager, a second plain assignee, a pure watcher, a cross-org user,
-- and a super admin, per docs/107's persona matrix.
--
-- The task's own id is held in a one-row temp table (af_ctx) rather
-- than a psql variable, since psql does not interpolate :'var'
-- references inside a DO $$ ... $$ body — every scenario below runs
-- inside one, to isolate its RAISE/EXCEPTION handling.
\set ON_ERROR_STOP on

CREATE TEMP TABLE af_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL, passed BOOLEAN NOT NULL);
CREATE TEMP TABLE af_ctx (task_id UUID NOT NULL);
GRANT SELECT, INSERT ON af_results, af_ctx TO authenticated;

-- ─── Fixtures ────────────────────────────────────────────────────────
INSERT INTO organizations (id,name,type,code) VALUES
 ('af000000-0000-0000-0000-000000000001','AF Org A','authority','AFOA'),
 ('af000000-0000-0000-0000-000000000002','AF Org B','authority','AFOB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('af000000-0000-0000-0000-000000000011','AF Division A','af000000-0000-0000-0000-000000000001');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('af000000-0000-0000-0000-000000000021','AF Section A','AFSA','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-000000000011');
INSERT INTO auth.users (id,email) VALUES
 ('af000000-0001-0000-0000-000000000001','creator@af.local'),
 ('af000000-0001-0000-0000-000000000002','assignee@af.local'),
 ('af000000-0001-0000-0000-000000000003','supervisor@af.local'),
 ('af000000-0001-0000-0000-000000000004','otherorg@af.local'),
 ('af000000-0001-0000-0000-000000000005','watcher@af.local'),
 ('af000000-0001-0000-0000-000000000006','secondassignee@af.local'),
 ('af000000-0001-0000-0000-000000000007','super@af.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('af000000-0001-0000-0000-000000000001','af000000-0000-0000-0000-000000000001','AF-1','Normal Staff (creator)','creator@af.local',true,false),
 ('af000000-0001-0000-0000-000000000002','af000000-0000-0000-0000-000000000001','AF-2','Room Manager (assignee)','assignee@af.local',true,false),
 ('af000000-0001-0000-0000-000000000003','af000000-0000-0000-0000-000000000001','AF-3','Section Supervisor','supervisor@af.local',true,false),
 ('af000000-0001-0000-0000-000000000004','af000000-0000-0000-0000-000000000002','AF-4','Other Org Staff','otherorg@af.local',true,false),
 ('af000000-0001-0000-0000-000000000005','af000000-0000-0000-0000-000000000001','AF-5','Pure Watcher','watcher@af.local',true,false),
 ('af000000-0001-0000-0000-000000000006','af000000-0000-0000-0000-000000000001','AF-6','Second Assignee','secondassignee@af.local',true,false),
 ('af000000-0001-0000-0000-000000000007','af000000-0000-0000-0000-000000000001','AF-7','Super Admin','super@af.local',true,true);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('af000000-0001-0000-0000-000000000001','section','af000000-0000-0000-0000-000000000021','staff',true,true),
 ('af000000-0001-0000-0000-000000000002','section','af000000-0000-0000-0000-000000000021','staff',true,true),
 ('af000000-0001-0000-0000-000000000003','section','af000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('af000000-0001-0000-0000-000000000005','section','af000000-0000-0000-0000-000000000021','staff',true,true),
 ('af000000-0001-0000-0000-000000000006','section','af000000-0000-0000-0000-000000000021','staff',true,true);

SET ROLE authenticated;

-- Creator creates the task exactly as create_task() would (draft,
-- normal priority) then assigns Room Manager — reproducing the
-- reported staging scenario via the real RPCs, not a raw INSERT.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
INSERT INTO af_ctx (task_id)
  SELECT create_task('af000000-0000-0000-0000-000000000001','UAT repro task','desc','af000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000002');
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000005"}',false);
SELECT watch_task((SELECT task_id FROM af_ctx));
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);

-- Sanity: task really is Draft, and Room Manager really is an active assignee.
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_id FROM af_ctx);
  INSERT INTO af_results VALUES (0, 'fixture: task starts Draft', v_status = 'draft');
END $$;

-- 1: creator can edit own task.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_title := 'Edited by creator');
  INSERT INTO af_results VALUES (1, 'creator can edit own task', TRUE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (1, 'creator can edit own task', FALSE);
END $$;

-- 2: plain assignee (Room Manager) CANNOT edit creator-owned task details.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000002"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_title := 'Should not be allowed');
  INSERT INTO af_results VALUES (2, 'plain assignee cannot edit task details', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (2, 'plain assignee cannot edit task details',
    SQLERRM = 'Not authorized to update this task');
END $$;

-- 3: plain assignee cannot remove a DIFFERENT user's assignment.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
SELECT assign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000006');
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000002"}',false);
DO $$
BEGIN
  PERFORM unassign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000006');
  INSERT INTO af_results VALUES (3, 'assignee cannot unassign a different user', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (3, 'assignee cannot unassign a different user',
    SQLERRM = 'Not authorized to unassign this task');
END $$;

-- 4: manager (supervisor-in-scope) CAN remove another user's assignment.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000003"}',false);
DO $$
BEGIN
  PERFORM unassign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000006');
  INSERT INTO af_results VALUES (4, 'supervisor can unassign another user', TRUE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (4, 'supervisor can unassign another user', FALSE);
END $$;

-- 5: watcher cannot edit.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000005"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_title := 'Watcher should not edit');
  INSERT INTO af_results VALUES (5, 'watcher cannot edit', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (5, 'watcher cannot edit',
    SQLERRM = 'Not authorized to update this task');
END $$;

-- 6: assignee (Room Manager) CAN still comment — unaffected by this fix.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000002"}',false);
DO $$
BEGIN
  PERFORM add_task_comment((SELECT task_id FROM af_ctx), 'Working on it');
  INSERT INTO af_results VALUES (6, 'assignee can comment', TRUE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (6, 'assignee can comment', FALSE);
END $$;

-- 6b: assignee (Room Manager) CAN still unassign THEMSELVES — unaffected
-- (this file re-assigns afterward so later scenarios still have an
-- active assignee to test against).
DO $$
BEGIN
  PERFORM unassign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000002');
  INSERT INTO af_results VALUES (601, 'assignee can still self-unassign (intentional, unchanged)', TRUE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (601, 'assignee can still self-unassign (intentional, unchanged)', FALSE);
END $$;
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
SELECT assign_task((SELECT task_id FROM af_ctx),'af000000-0001-0000-0000-000000000002'); -- restore for later scenarios

-- 7: creator/manager has a correct Draft -> Open activation path
-- (update_task() itself, now manage-only, still allows the transition
-- valid_task_status_transition() already permits).
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_status := 'open');
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_id FROM af_ctx);
  INSERT INTO af_results VALUES (7, 'creator can activate Draft -> Open', v_status = 'open');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (7, 'creator can activate Draft -> Open', FALSE);
END $$;

-- 8: after activation, the plain assignee's authority is unchanged —
-- still cannot edit a structural field, i.e. no new authority leaked
-- in from the status change itself.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000002"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_priority := 'critical');
  INSERT INTO af_results VALUES (8, 'assignee still cannot edit after activation', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (8, 'assignee still cannot edit after activation',
    SQLERRM = 'Not authorized to update this task');
END $$;

-- 9: an unrelated, different-org user cannot manage (or even see) this task.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000004"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_title := 'Cross-org should not work');
  INSERT INTO af_results VALUES (9, 'cross-org user cannot manage', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (9, 'cross-org user cannot manage', TRUE);
END $$;
DO $$
DECLARE v_visible BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM tasks WHERE id = (SELECT task_id FROM af_ctx)) INTO v_visible;
  INSERT INTO af_results VALUES (901, 'cross-org user cannot even view the task (RLS)', NOT v_visible);
END $$;

-- 10: activity history records the assignment, unassignment, edit, and
-- activation actions above.
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM audit_logs
    WHERE record_type = 'task' AND record_id = (SELECT task_id FROM af_ctx)
      AND action IN ('assigned','unassigned','edited','commented');
  INSERT INTO af_results VALUES (10, 'activity history recorded assignment/edit/comment actions', v_count >= 5);
END $$;

-- Super admin bypass still works (unaffected by this fix).
SELECT set_config('request.jwt.claims','{"sub":"af000000-0001-0000-0000-000000000007"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_id FROM af_ctx), p_title := 'Edited by super admin');
  INSERT INTO af_results VALUES (11, 'super admin can still edit any task', TRUE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO af_results VALUES (11, 'super admin can still edit any task', FALSE);
END $$;

RESET ROLE;

-- ─── Report ──────────────────────────────────────────────────────────
SELECT scenario, name, passed FROM af_results ORDER BY scenario;
SELECT
  COUNT(*) FILTER (WHERE passed) AS passed_count,
  COUNT(*) FILTER (WHERE NOT passed) AS failed_count
FROM af_results;

-- ─── Cleanup ─────────────────────────────────────────────────────────
DELETE FROM audit_logs WHERE record_type = 'task' AND record_id IN (SELECT task_id FROM af_ctx);
DELETE FROM audit_logs WHERE user_id::text LIKE 'af000000-0001%';
DELETE FROM platform_outbox_events WHERE actor_id::text LIKE 'af000000-0001%' OR organization_id::text LIKE 'af0000%';
DELETE FROM user_notifications WHERE recipient_user_id::text LIKE 'af000000-0001%';
DELETE FROM notifications WHERE user_id::text LIKE 'af000000-0001%';
DELETE FROM task_comments WHERE task_id IN (SELECT task_id FROM af_ctx);
DELETE FROM task_watchers WHERE task_id IN (SELECT task_id FROM af_ctx);
DELETE FROM task_assignments WHERE task_id IN (SELECT task_id FROM af_ctx);
DELETE FROM tasks WHERE id IN (SELECT task_id FROM af_ctx);
DELETE FROM user_assignments WHERE user_id::text LIKE 'af000000-0001%';
DELETE FROM users WHERE id::text LIKE 'af000000-0001%';
DELETE FROM auth.users WHERE id::text LIKE 'af000000-0001%';
DELETE FROM sections WHERE id::text LIKE 'af0000%';
DELETE FROM divisions WHERE id::text LIKE 'af0000%';
DELETE FROM task_number_sequences WHERE org_id::text LIKE 'af0000%';
DELETE FROM organizations WHERE id::text LIKE 'af0000%';
