-- CorLink — behavioral test for the UAT "Start Work" action +
-- assignment accountability correction (docs/111).
-- Disposable/local PostgreSQL only. Creates fixed ac000000... fixtures
-- and removes them at the end.
--
-- Covers two independent findings:
--   START WORK (1-8) — proves update_task()'s existing Open -> In
--   Progress path (unchanged by this milestone) is exactly what the
--   new frontend "Start Work" button relies on: an active assignee's
--   pure start request succeeds when unblocked, is rejected by the
--   dependency check when blocked and succeeds once resolved, cannot
--   bypass Draft -> Open, cannot smuggle a structural edit alongside
--   the status change, and is denied to unrelated/cross-org/anonymous
--   callers.
--   ASSIGNMENT ACCOUNTABILITY (9-15) — proves unassign_task() (this
--   file's actual SQL change) now rejects a caller removing their OWN
--   assignment, still rejects removing someone ELSE's assignment as a
--   plain assignee, and that creator/supervisor manage-tier removal,
--   assignment, and re-assignment, and audit evidence, all still work
--   exactly as before.
--
-- Task ids are held in a one-row temp table (sw_ctx) rather than a
-- psql variable, since psql does not interpolate :'var' references
-- inside a DO $$ ... $$ body — every scenario below runs inside one,
-- to isolate its RAISE/EXCEPTION handling.
\set ON_ERROR_STOP on

CREATE TEMP TABLE sw_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL, passed BOOLEAN NOT NULL);
CREATE TEMP TABLE sw_ctx (
  task_a_id UUID, task_b_id UUID, task_b_prereq_id UUID,
  task_c_id UUID, task_d_id UUID, task_e_id UUID, task_f_id UUID
);
INSERT INTO sw_ctx DEFAULT VALUES;
GRANT SELECT, INSERT, UPDATE ON sw_results, sw_ctx TO authenticated, anon;

-- ─── Fixtures ────────────────────────────────────────────────────────
INSERT INTO organizations (id,name,type,code) VALUES
 ('ac000000-0000-0000-0000-000000000001','AC Org A','authority','ACOA'),
 ('ac000000-0000-0000-0000-000000000002','AC Org B','authority','ACOB');
INSERT INTO divisions (id,name,org_id) VALUES
 ('ac000000-0000-0000-0000-000000000011','AC Division A','ac000000-0000-0000-0000-000000000001');
INSERT INTO sections (id,name,code,org_id,division_id) VALUES
 ('ac000000-0000-0000-0000-000000000021','AC Section A','ACSA','ac000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000011');
INSERT INTO auth.users (id,email) VALUES
 ('ac000000-0001-0000-0000-000000000001','creator@ac.local'),
 ('ac000000-0001-0000-0000-000000000002','assignee@ac.local'),
 ('ac000000-0001-0000-0000-000000000003','supervisor@ac.local'),
 ('ac000000-0001-0000-0000-000000000004','otherorg@ac.local'),
 ('ac000000-0001-0000-0000-000000000005','unrelated@ac.local'),
 ('ac000000-0001-0000-0000-000000000006','secondassignee@ac.local'),
 ('ac000000-0001-0000-0000-000000000007','super@ac.local');
INSERT INTO users (id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('ac000000-0001-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','AC-1','Normal Staff (creator)','creator@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000002','ac000000-0000-0000-0000-000000000001','AC-2','Room Manager (assignee)','assignee@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000003','ac000000-0000-0000-0000-000000000001','AC-3','Section Supervisor','supervisor@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000004','ac000000-0000-0000-0000-000000000002','AC-4','Other Org Staff','otherorg@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000005','ac000000-0000-0000-0000-000000000001','AC-5','Unrelated Staff','unrelated@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000006','ac000000-0000-0000-0000-000000000001','AC-6','Second Assignee','secondassignee@ac.local',true,false),
 ('ac000000-0001-0000-0000-000000000007','ac000000-0000-0000-0000-000000000001','AC-7','Super Admin','super@ac.local',true,true);
INSERT INTO user_assignments (user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('ac000000-0001-0000-0000-000000000001','section','ac000000-0000-0000-0000-000000000021','staff',true,true),
 ('ac000000-0001-0000-0000-000000000002','section','ac000000-0000-0000-0000-000000000021','staff',true,true),
 ('ac000000-0001-0000-0000-000000000003','section','ac000000-0000-0000-0000-000000000021','supervisor',true,true),
 ('ac000000-0001-0000-0000-000000000005','section','ac000000-0000-0000-0000-000000000021','staff',true,true),
 ('ac000000-0001-0000-0000-000000000006','section','ac000000-0000-0000-0000-000000000021','staff',true,true);

SET ROLE authenticated;

-- ══════════════════════════════════════════════════════════════════
-- START WORK (1-8)
-- ══════════════════════════════════════════════════════════════════

-- Task A: Open, assigned to Room Manager, no dependencies.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_a_id =
  create_task('ac000000-0000-0000-0000-000000000001','Start Work — no prerequisite','desc','ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_a_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
SELECT update_task((SELECT task_a_id FROM sw_ctx), p_status := 'open');

-- 1: Open Task + active assignee + no unresolved prerequisite -> In Progress succeeds.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_a_id FROM sw_ctx), p_status := 'in_progress');
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_a_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (1, 'Open task, active assignee, no prerequisite: Start Work succeeds', v_status = 'in_progress');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (1, 'Open task, active assignee, no prerequisite: Start Work succeeds', FALSE);
END $$;

-- Task B: Open, assigned to Room Manager, blocked by an unresolved prerequisite.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_b_id =
  create_task('ac000000-0000-0000-0000-000000000001','Start Work — blocked','desc','ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_b_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
SELECT update_task((SELECT task_b_id FROM sw_ctx), p_status := 'open');
UPDATE sw_ctx SET task_b_prereq_id =
  create_task('ac000000-0000-0000-0000-000000000001','Start Work — prerequisite',NULL,'ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT create_task_dependency((SELECT task_b_id FROM sw_ctx), (SELECT task_b_prereq_id FROM sw_ctx));

-- 2: Open Task + unresolved prerequisite -> Start Work blocked.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_b_id FROM sw_ctx), p_status := 'in_progress');
  INSERT INTO sw_results VALUES (2, 'Open task with unresolved prerequisite: Start Work blocked', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_b_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (2, 'Open task with unresolved prerequisite: Start Work blocked',
    SQLERRM = 'Task cannot be started because one or more prerequisites are unresolved.' AND v_status = 'open');
END $$;

-- Resolve the prerequisite (creator moves it through its own required chain).
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
DO $$
BEGIN
  PERFORM update_task((SELECT task_b_prereq_id FROM sw_ctx), p_status := 'open');
  PERFORM update_task((SELECT task_b_prereq_id FROM sw_ctx), p_status := 'in_progress');
  PERFORM complete_task((SELECT task_b_prereq_id FROM sw_ctx));
END $$;

-- 3: once resolved, Start Work succeeds.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_b_id FROM sw_ctx), p_status := 'in_progress');
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_b_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (3, 'Start Work succeeds once the prerequisite is resolved', v_status = 'in_progress');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (3, 'Start Work succeeds once the prerequisite is resolved', FALSE);
END $$;

-- Task C: stays Draft, assigned to Room Manager.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_c_id =
  create_task('ac000000-0000-0000-0000-000000000001','Draft bypass attempt',NULL,'ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_c_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');

-- 4: Draft Task + assignee -> assignee cannot bypass Draft -> Open (the
-- allow-list has no (draft,in_progress) entry; this is the same
-- transition guard for every actor, asserted here specifically against
-- the assignee to prove no authorization side-channel skips it).
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_c_id FROM sw_ctx), p_status := 'in_progress');
  INSERT INTO sw_results VALUES (4, 'Draft task: assignee cannot bypass Draft -> Open directly to In Progress', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_c_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (4, 'Draft task: assignee cannot bypass Draft -> Open directly to In Progress',
    SQLERRM LIKE '%Invalid task status transition%' AND v_status = 'draft');
END $$;

-- Task D: Open, assigned to Room Manager — for the bundled-edit test.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_d_id =
  create_task('ac000000-0000-0000-0000-000000000001','Bundled edit attempt','original','ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_d_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
SELECT update_task((SELECT task_d_id FROM sw_ctx), p_status := 'open');

-- 5: bundled structural edit + In Progress request -> denied, no side channel.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_status TEXT; v_title TEXT;
BEGIN
  PERFORM update_task((SELECT task_d_id FROM sw_ctx), p_title := 'Sneaky bundled edit', p_status := 'in_progress');
  INSERT INTO sw_results VALUES (5, 'Assignee cannot bundle a structural edit with a start request', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT status, title INTO v_status, v_title FROM tasks WHERE id = (SELECT task_d_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (5, 'Assignee cannot bundle a structural edit with a start request',
    SQLERRM = 'Not authorized to update this task' AND v_status = 'open' AND v_title = 'Bundled edit attempt');
END $$;

-- Task E: Open, assigned ONLY to Room Manager — for unrelated/cross-org/anon denial.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_e_id =
  create_task('ac000000-0000-0000-0000-000000000001','Unrelated/cross-org/anon denial',NULL,'ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_e_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
SELECT update_task((SELECT task_e_id FROM sw_ctx), p_status := 'open');

-- 6: unrelated same-org user (never assigned, not manage-tier) cannot Start Work.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000005"}',false);
DO $$
DECLARE v_status TEXT;
BEGIN
  PERFORM update_task((SELECT task_e_id FROM sw_ctx), p_status := 'in_progress');
  INSERT INTO sw_results VALUES (6, 'Unrelated same-org user cannot Start Work', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT status INTO v_status FROM tasks WHERE id = (SELECT task_e_id FROM sw_ctx);
  INSERT INTO sw_results VALUES (6, 'Unrelated same-org user cannot Start Work',
    SQLERRM = 'Not authorized to update this task' AND v_status = 'open');
END $$;

-- 7: cross-org user is denied. update_task() itself is SECURITY DEFINER
-- (it looks the row up directly, bypassing RLS), so the authorization
-- check inside it is what actually denies this — not visibility. A
-- plain SELECT as this same cross-org user (ordinary SELECT-RLS,
-- can_view_task()) independently confirms the task is invisible to
-- them too, the same fail-closed shape proven elsewhere in this suite.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000004"}',false);
DO $$
DECLARE v_visible BOOLEAN;
BEGIN
  PERFORM update_task((SELECT task_e_id FROM sw_ctx), p_status := 'in_progress');
  INSERT INTO sw_results VALUES (7, 'Cross-org user cannot Start Work', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT EXISTS(SELECT 1 FROM tasks WHERE id = (SELECT task_e_id FROM sw_ctx)) INTO v_visible;
  INSERT INTO sw_results VALUES (7, 'Cross-org user cannot Start Work',
    SQLERRM = 'Not authorized to update this task' AND NOT v_visible);
END $$;

-- 8: anonymous (unauthenticated) caller is denied.
SELECT set_config('request.jwt.claims', NULL, false);
SET ROLE anon;
DO $$
BEGIN
  PERFORM update_task((SELECT task_e_id FROM sw_ctx), p_status := 'in_progress');
  INSERT INTO sw_results VALUES (8, 'Anonymous caller cannot Start Work', FALSE);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (8, 'Anonymous caller cannot Start Work',
    SQLERRM = 'update_task requires an authenticated caller');
END $$;
RESET ROLE;
SET ROLE authenticated;

-- ══════════════════════════════════════════════════════════════════
-- ASSIGNMENT ACCOUNTABILITY (9-15)
-- ══════════════════════════════════════════════════════════════════

-- Task F: assigned to Room Manager AND Second Assignee.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
UPDATE sw_ctx SET task_f_id =
  create_task('ac000000-0000-0000-0000-000000000001','Assignment accountability',NULL,'ac000000-0000-0000-0000-000000000021','normal','section',NULL,NULL);
SELECT assign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
SELECT assign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000006');

-- 9: active assignee (Room Manager) cannot unassign SELF anymore.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_still_active BOOLEAN;
BEGIN
  PERFORM unassign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
  INSERT INTO sw_results VALUES (9, 'Active assignee cannot unassign self', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000002' AND is_active) INTO v_still_active;
  INSERT INTO sw_results VALUES (9, 'Active assignee cannot unassign self',
    SQLERRM = 'Not authorized to unassign this task' AND v_still_active);
END $$;

-- 10: assignee cannot remove a DIFFERENT assignee either.
DO $$
DECLARE v_still_active BOOLEAN;
BEGIN
  PERFORM unassign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000006');
  INSERT INTO sw_results VALUES (10, 'Assignee cannot remove another assignee', FALSE);
EXCEPTION WHEN OTHERS THEN
  SELECT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000006' AND is_active) INTO v_still_active;
  INSERT INTO sw_results VALUES (10, 'Assignee cannot remove another assignee',
    SQLERRM = 'Not authorized to unassign this task' AND v_still_active);
END $$;

-- 11: creator (manage-tier) CAN remove an assignee, including one who
-- just failed to remove themselves.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_removed BOOLEAN;
BEGIN
  PERFORM unassign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000006');
  SELECT NOT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000006' AND is_active) INTO v_removed;
  INSERT INTO sw_results VALUES (11, 'Creator (manage-tier) can remove an assignee', v_removed);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (11, 'Creator (manage-tier) can remove an assignee', FALSE);
END $$;

-- 12: supervisor-in-scope (manage-tier) behavior preserved — can also
-- remove an assignee, a distinct manage-tier branch from creator's.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000003"}',false);
DO $$
DECLARE v_removed BOOLEAN;
BEGIN
  PERFORM unassign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
  SELECT NOT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000002' AND is_active) INTO v_removed;
  INSERT INTO sw_results VALUES (12, 'Supervisor-in-scope (manage-tier) can remove an assignee', v_removed);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (12, 'Supervisor-in-scope (manage-tier) can remove an assignee', FALSE);
END $$;

-- 13: assignment still works — assign_task() is completely unaffected.
SELECT set_config('request.jwt.claims','{"sub":"ac000000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_active BOOLEAN;
BEGIN
  PERFORM assign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
  SELECT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000002' AND is_active) INTO v_active;
  INSERT INTO sw_results VALUES (13, 'Assignment (assign_task) still works', v_active);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (13, 'Assignment (assign_task) still works', FALSE);
END $$;

-- 14: the full remove-then-reassign cycle still works end-to-end
-- (manage-tier unassign followed by a fresh assign_task for the same
-- user — proves the two RPCs still compose correctly together).
DO $$
DECLARE v_active BOOLEAN;
BEGIN
  PERFORM unassign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
  PERFORM assign_task((SELECT task_f_id FROM sw_ctx),'ac000000-0001-0000-0000-000000000002');
  SELECT EXISTS(SELECT 1 FROM task_assignments WHERE task_id = (SELECT task_f_id FROM sw_ctx)
    AND user_id = 'ac000000-0001-0000-0000-000000000002' AND is_active) INTO v_active;
  INSERT INTO sw_results VALUES (14, 'Re-assignment (remove then re-add the same user) still works', v_active);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sw_results VALUES (14, 'Re-assignment (remove then re-add the same user) still works', FALSE);
END $$;

-- 15: audit evidence is correct — exactly the expected 'assigned'/
-- 'unassigned' row counts for Task F, attributed to the actors who
-- actually performed each mutation, and crucially NO 'unassigned' row
-- was ever written with the assignee themselves as actor (their two
-- failed self/other-unassign attempts at 9-10 wrote nothing).
DO $$
DECLARE v_assigned_count INT; v_unassigned_count INT; v_self_unassign_rows INT;
BEGIN
  SELECT COUNT(*) FILTER (WHERE action = 'assigned'), COUNT(*) FILTER (WHERE action = 'unassigned')
    INTO v_assigned_count, v_unassigned_count
  FROM audit_logs WHERE record_type = 'task' AND record_id = (SELECT task_f_id FROM sw_ctx);
  SELECT COUNT(*) INTO v_self_unassign_rows FROM audit_logs
    WHERE record_type = 'task' AND record_id = (SELECT task_f_id FROM sw_ctx)
      AND action = 'unassigned' AND user_id = 'ac000000-0001-0000-0000-000000000002';
  INSERT INTO sw_results VALUES (15, 'Audit evidence: correct assigned/unassigned counts, no successful self-unassign row',
    v_assigned_count = 4 AND v_unassigned_count = 3 AND v_self_unassign_rows = 0);
END $$;

RESET ROLE;

-- ─── Report ──────────────────────────────────────────────────────────
SELECT scenario, name, passed FROM sw_results ORDER BY scenario;
SELECT
  COUNT(*) FILTER (WHERE passed) AS passed_count,
  COUNT(*) FILTER (WHERE NOT passed) AS failed_count
FROM sw_results;

-- ─── Cleanup ─────────────────────────────────────────────────────────
CREATE TEMP TABLE sw_all_task_ids AS
  SELECT task_a_id AS id FROM sw_ctx WHERE task_a_id IS NOT NULL
  UNION SELECT task_b_id FROM sw_ctx WHERE task_b_id IS NOT NULL
  UNION SELECT task_b_prereq_id FROM sw_ctx WHERE task_b_prereq_id IS NOT NULL
  UNION SELECT task_c_id FROM sw_ctx WHERE task_c_id IS NOT NULL
  UNION SELECT task_d_id FROM sw_ctx WHERE task_d_id IS NOT NULL
  UNION SELECT task_e_id FROM sw_ctx WHERE task_e_id IS NOT NULL
  UNION SELECT task_f_id FROM sw_ctx WHERE task_f_id IS NOT NULL;

DELETE FROM audit_logs WHERE record_type = 'task' AND record_id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM audit_logs WHERE user_id::text LIKE 'ac000000-0001%';
DELETE FROM platform_outbox_events WHERE actor_id::text LIKE 'ac000000-0001%' OR organization_id::text LIKE 'ac0000%';
DELETE FROM user_notifications WHERE recipient_user_id::text LIKE 'ac000000-0001%';
DELETE FROM notifications WHERE user_id::text LIKE 'ac000000-0001%';
DELETE FROM task_comments WHERE task_id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM task_watchers WHERE task_id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM task_assignments WHERE task_id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM task_dependencies WHERE dependent_task_id IN (SELECT id FROM sw_all_task_ids) OR prerequisite_task_id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM tasks WHERE id IN (SELECT id FROM sw_all_task_ids);
DELETE FROM user_assignments WHERE user_id::text LIKE 'ac000000-0001%';
DELETE FROM users WHERE id::text LIKE 'ac000000-0001%';
DELETE FROM auth.users WHERE id::text LIKE 'ac000000-0001%';
DELETE FROM sections WHERE id::text LIKE 'ac0000%';
DELETE FROM divisions WHERE id::text LIKE 'ac0000%';
DELETE FROM task_number_sequences WHERE org_id::text LIKE 'ac0000%';
DELETE FROM organizations WHERE id::text LIKE 'ac0000%';
