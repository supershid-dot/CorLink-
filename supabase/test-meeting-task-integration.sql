-- ============================================================
-- CorLink — Behavioral/RLS test: Meetings ↔ Shared Tasks Integration
-- Companion to supabase/patch-meeting-task-integration.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (one
-- organization, sections/users, and a meeting, all with fixed
-- 'bbbbbbbb-...'-prefixed UUIDs) and exercises every RPC under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation. Run this ONLY against a disposable/local test
-- database that already has the full migration chain through
-- patch-meeting-task-integration.sql applied — NEVER against staging
-- or production. It is idempotent (fixtures use ON CONFLICT DO
-- NOTHING) but not side-effect-free: it creates real rows.
--
-- Requires (in the connecting session, once, before running this
-- file — a Supabase-platform-provided baseline in a real project,
-- only needs stubbing manually on a bare local Postgres instance):
--   GRANT USAGE ON SCHEMA public TO authenticated;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
--   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
--
-- Every assertion below is a real DO $$ ... RAISE EXCEPTION $$ block —
-- this file hard-fails (aborts) at the first wrong answer. Fixture ids
-- are read from the test_ids temp table (not psql :variables) inside
-- DO $$ blocks, same technique test-request-task-integration.sql uses,
-- since psql does not substitute :variables inside dollar-quoted
-- strings. A clean run ends with the final "ALL MEETING TASK
-- INTEGRATION TESTS PASSED" notice.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- One org, one command/department/section hierarchy, 5 users
-- (creator = the meeting's own creator, manager = a same-org
-- supervisor who did NOT create it, assignee, an uninvolved same-org
-- outsider, and a cross-org user), and one 'scheduled', 'participants'
-- -visibility meeting with the meetings module explicitly enabled for
-- the org (disabled by default — confirmed via seed.sql's own
-- organization_modules rows).
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('bbbbbbbb-0000-0000-0000-000000000001', 'R5 Test Org', 'mcs', 'R5O'),
    ('bbbbbbbb-0000-0000-0000-000000000002', 'R5 Test Other Org', 'authority', 'R5B')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('bbbbbbbb-0000-0000-0000-000000000010', 'R5 Test Command', 'bbbbbbbb-0000-0000-0000-000000000001'),
    ('bbbbbbbb-0000-0000-0000-000000000011', 'R5 Test Other Command', 'bbbbbbbb-0000-0000-0000-000000000002')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('bbbbbbbb-0000-0000-0000-000000000020', 'R5 Test Department', 'bbbbbbbb-0000-0000-0000-000000000010'),
    ('bbbbbbbb-0000-0000-0000-000000000021', 'R5 Test Other Department', 'bbbbbbbb-0000-0000-0000-000000000011')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('bbbbbbbb-0000-0000-0000-000000000030', 'R5 Test Section', 'R5S', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000020'),
    ('bbbbbbbb-0000-0000-0000-000000000032', 'R5 Test Second Section', 'R5S2', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000020'),
    ('bbbbbbbb-0000-0000-0000-000000000031', 'R5 Test Other Section', 'R5X', 'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000021')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('bbbbbbbb-1111-0000-0000-000000000001', 'r5test-creator@test.local'),
    ('bbbbbbbb-1111-0000-0000-000000000002', 'r5test-manager@test.local'),
    ('bbbbbbbb-1111-0000-0000-000000000003', 'r5test-assignee@test.local'),
    ('bbbbbbbb-1111-0000-0000-000000000004', 'r5test-outsider@test.local'),
    ('bbbbbbbb-1111-0000-0000-000000000005', 'r5test-otherorg@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('bbbbbbbb-1111-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'R5T-SN001', 'R5Test Creator', 'r5test-creator@test.local', TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001', 'R5T-SN002', 'R5Test Manager', 'r5test-manager@test.local', TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000001', 'R5T-SN003', 'R5Test Assignee', 'r5test-assignee@test.local', TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000001', 'R5T-SN004', 'R5Test Outsider', 'r5test-outsider@test.local', TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000005', 'bbbbbbbb-0000-0000-0000-000000000002', 'R5T-SN005', 'R5Test OtherOrg', 'r5test-otherorg@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
    ('bbbbbbbb-1111-0000-0000-000000000001', 'section', 'bbbbbbbb-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000002', 'section', 'bbbbbbbb-0000-0000-0000-000000000030', 'supervisor', TRUE, TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000003', 'section', 'bbbbbbbb-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000004', 'section', 'bbbbbbbb-0000-0000-0000-000000000032', 'staff', TRUE, TRUE),
    ('bbbbbbbb-1111-0000-0000-000000000005', 'section', 'bbbbbbbb-0000-0000-0000-000000000031', 'staff', TRUE, TRUE)
  ON CONFLICT DO NOTHING;

  -- Enable the Meetings module for the test org — disabled by default.
  INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT 'bbbbbbbb-0000-0000-0000-000000000001', pm.id, TRUE FROM platform_modules pm WHERE pm.module_key = 'meetings'
  ON CONFLICT (organization_id, module_id) DO UPDATE SET is_enabled = TRUE;

  INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  VALUES (
    'bbbbbbbb-2222-0000-0000-000000000001',
    'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-1111-0000-0000-000000000001',
    'R5 test meeting', 'general', 'scheduled', 'participants', 'Indian/Maldives',
    now() + interval '1 day', now() + interval '1 day 1 hour'
  ) ON CONFLICT (id) DO NOTHING;

  -- A second, disposable meeting used only by TEST 7 (cancellation) —
  -- kept separate from the main fixture meeting above so cancelling it
  -- doesn't leave the main meeting permanently cancelled and break a
  -- repeated run of every other test in this file (add_participant()
  -- and several other RPCs reject an already-cancelled meeting).
  INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  VALUES (
    'bbbbbbbb-2222-0000-0000-000000000002',
    'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-1111-0000-0000-000000000001',
    'R5 test meeting (cancellation target)', 'general', 'scheduled', 'participants', 'Indian/Maldives',
    now() + interval '2 day', now() + interval '2 day 1 hour'
  ) ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'Fixtures ready.';
END $$;

CREATE TEMP TABLE test_ids AS SELECT
  'bbbbbbbb-1111-0000-0000-000000000001'::uuid AS creator,
  'bbbbbbbb-1111-0000-0000-000000000002'::uuid AS manager,
  'bbbbbbbb-1111-0000-0000-000000000003'::uuid AS assignee,
  'bbbbbbbb-1111-0000-0000-000000000004'::uuid AS outsider,
  'bbbbbbbb-1111-0000-0000-000000000005'::uuid AS otherorg,
  'bbbbbbbb-0000-0000-0000-000000000001'::uuid AS org_a,
  'bbbbbbbb-0000-0000-0000-000000000030'::uuid AS section_a1,
  'bbbbbbbb-2222-0000-0000-000000000001'::uuid AS meeting_id,
  'bbbbbbbb-2222-0000-0000-000000000002'::uuid AS cancel_meeting_id;

CREATE TEMP TABLE t1 (task_id UUID, decision_id UUID, link_id UUID);

-- Temp tables are only readable by their owner by default — grant the
-- authenticated role access before switching to it below.
GRANT SELECT, INSERT, UPDATE ON test_ids, t1 TO authenticated;

SET ROLE authenticated;

-- ─── 1. Create Task from Meeting ────────────────────────────────
DO $$ BEGIN PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false); END $$;
INSERT INTO t1 (task_id, decision_id, link_id)
SELECT task_id, decision_id, link_id FROM create_meeting_task(
  (SELECT meeting_id FROM test_ids), 'R5 Test: follow up on decision', 'desc',
  (SELECT section_a1 FROM test_ids), 'high', 'section', NULL, NULL,
  ARRAY[(SELECT assignee FROM test_ids)],
  NULL, 'Approved the R5 test proposal', 'decided at the test meeting'
);
DO $$
DECLARE v_task_id UUID; v_decision_id UUID; v_link_id UUID; v_active_link INT; v_active_assignment INT; v_decision_count INT;
BEGIN
  SELECT task_id, decision_id, link_id INTO v_task_id, v_decision_id, v_link_id FROM t1;
  SELECT count(*) INTO v_active_link FROM task_links WHERE id = v_link_id AND removed_at IS NULL;
  SELECT count(*) INTO v_active_assignment FROM task_assignments WHERE task_id = v_task_id AND is_active;
  SELECT count(*) INTO v_decision_count FROM meeting_decisions WHERE id = v_decision_id AND meeting_id = (SELECT meeting_id FROM test_ids);
  IF v_task_id IS NULL OR v_decision_id IS NULL OR v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_meeting_task returned a null id';
  END IF;
  IF v_active_link <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active link, got %', v_active_link;
  END IF;
  IF v_active_assignment <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active assignment, got %', v_active_assignment;
  END IF;
  IF v_decision_count <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: decision row not created against the right meeting';
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: create_meeting_task created a decision, a task, an assignment, and a link';
END $$;

-- ─── 2. Link existing Task ──────────────────────────────────────
DO $$
DECLARE v_task2_id UUID; v_org_a UUID; v_section_a1 UUID; v_meeting_id UUID; v_link_id UUID;
BEGIN
  SELECT org_a, section_a1, meeting_id INTO v_org_a, v_section_a1, v_meeting_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  v_task2_id := create_task(v_org_a, 'R5 Test: second supporting task', NULL, v_section_a1);
  v_link_id := link_existing_task_to_meeting(v_task2_id, v_meeting_id, NULL, 'A second, unrelated decision', NULL);
  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 2 FAILED: link_existing_task_to_meeting returned null';
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: link_existing_task_to_meeting linked a pre-existing task to a new decision';
END $$;

-- unauthorized same-org outsider cannot create/link
DO $$
DECLARE v_meeting_id UUID; v_task_id UUID;
BEGIN
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  BEGIN
    PERFORM create_meeting_task(v_meeting_id, 'sneaky', NULL, NULL, 'normal', 'section', NULL, NULL, NULL, NULL, 'sneaky decision', NULL);
    RAISE EXCEPTION 'TEST 2B FAILED: outsider create_meeting_task succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 2B FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 2B PASSED: unauthorized same-org user rejected from create_meeting_task';
END $$;

-- ─── 3. Unlink ───────────────────────────────────────────────────
DO $$
DECLARE
  v_task_id UUID; v_link_id UUID; v_meeting_id UUID;
  v_task_status_before TEXT; v_meeting_status_before TEXT;
  v_removed_at TIMESTAMPTZ; v_row_count INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1;
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_meeting_status_before FROM meetings WHERE id = v_meeting_id;

  PERFORM unlink_task_from_meeting(v_link_id, 'test unlink');

  SELECT removed_at, count(*) OVER() INTO v_removed_at, v_row_count FROM task_links WHERE id = v_link_id;
  IF v_removed_at IS NULL THEN
    RAISE EXCEPTION 'TEST 3 FAILED: link row removed_at was not set';
  END IF;
  IF v_row_count <> 1 THEN
    RAISE EXCEPTION 'TEST 3 FAILED: link row was hard-deleted, history not retained';
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 3 FAILED: task status changed on unlink';
  END IF;
  IF (SELECT status FROM meetings WHERE id = v_meeting_id) <> v_meeting_status_before THEN
    RAISE EXCEPTION 'TEST 3 FAILED: meeting status changed on unlink';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: unlink soft-removes only, task/meeting status untouched, history retained';
END $$;

-- re-link so later tests have an active link on t1's task/decision
DO $$
DECLARE v_task_id UUID; v_decision_id UUID; v_meeting_id UUID; v_new_link_id UUID;
BEGIN
  SELECT task_id, decision_id INTO v_task_id, v_decision_id FROM t1;
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  v_new_link_id := link_existing_task_to_meeting(v_task_id, v_meeting_id, v_decision_id, NULL, NULL);
  UPDATE t1 SET link_id = v_new_link_id;
END $$;

-- ─── 4. Visibility: can view Task but not Meeting, and vice versa ──
-- Outsider gets assigned to the task (can now view the task) while
-- remaining a non-participant of the meeting (cannot view the meeting).
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  PERFORM assign_task(v_task_id, v_outsider);
END $$;
DO $$
DECLARE v_task_id UUID; v_decision_id UUID; v_can_view_task BOOLEAN; v_can_view_meeting BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id, decision_id INTO v_task_id, v_decision_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_meeting := can_view_meeting((SELECT meeting_id FROM test_ids));
  v_can_view_link := can_view_task_link(v_task_id, 'meeting', v_decision_id);
  IF NOT v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4 FAILED: newly-assigned outsider should now see the task';
  END IF;
  IF v_can_view_meeting THEN
    RAISE EXCEPTION 'TEST 4 FAILED: non-participant outsider should not see a participants-visibility meeting';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4 FAILED: outsider should not see the link (can view task but not meeting)';
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: user who can view the Task but not the Meeting cannot see the link';
END $$;
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  PERFORM unassign_task(v_task_id, v_outsider);
END $$;

-- Now the reverse: add outsider as a meeting participant (can now view
-- the meeting) while they remain unrelated to the task (section-scoped
-- visibility, different section) — can view meeting but not task.
DO $$
DECLARE v_meeting_id UUID; v_outsider UUID;
BEGIN
  SELECT meeting_id, outsider INTO v_meeting_id, v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  IF NOT EXISTS (
    SELECT 1 FROM meeting_participants WHERE meeting_id = v_meeting_id AND user_id = v_outsider AND removed_at IS NULL
  ) THEN
    PERFORM add_participant(v_meeting_id, v_outsider);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_decision_id UUID; v_can_view_task BOOLEAN; v_can_view_meeting BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id, decision_id INTO v_task_id, v_decision_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_meeting := can_view_meeting((SELECT meeting_id FROM test_ids));
  v_can_view_link := can_view_task_link(v_task_id, 'meeting', v_decision_id);
  IF NOT v_can_view_meeting THEN
    RAISE EXCEPTION 'TEST 4B FAILED: outsider added as a participant should now see the meeting';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4B FAILED: outsider should still not see the section-scoped task';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4B FAILED: outsider should not see the link (can view meeting but not task)';
  END IF;
  RAISE NOTICE 'TEST 4B PASSED: user who can view the Meeting but not the Task cannot see the link';
END $$;
-- Reset outsider back to non-participant so a repeated run of this
-- file starts TEST 4/4B from the same state every time (participant
-- rows are not covered by the fixtures' ON CONFLICT DO NOTHING, since
-- add_participant() is a real mutation, not a fixture insert).
DO $$
DECLARE v_meeting_id UUID; v_outsider UUID; v_participant_id UUID;
BEGIN
  SELECT meeting_id, outsider INTO v_meeting_id, v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  SELECT id INTO v_participant_id FROM meeting_participants
  WHERE meeting_id = v_meeting_id AND user_id = v_outsider AND removed_at IS NULL;
  IF v_participant_id IS NOT NULL THEN
    PERFORM remove_participant(v_participant_id, 'test cleanup');
  END IF;
END $$;

-- ─── 5. Cross-org denial ─────────────────────────────────────────
DO $$
DECLARE v_task_id UUID; v_decision_id UUID; v_meeting_id UUID; v_can_view_meeting BOOLEAN; v_can_view_task BOOLEAN; v_list_count INT;
BEGIN
  SELECT task_id, decision_id INTO v_task_id, v_decision_id FROM t1;
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);
  v_can_view_meeting := can_view_meeting(v_meeting_id);
  v_can_view_task := can_view_task(v_task_id);
  SELECT count(*) INTO v_list_count FROM list_meeting_tasks(v_meeting_id);
  IF v_can_view_meeting THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should not see the meeting at all';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should not see the task';
  END IF;
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should see 0 meeting tasks, saw %', v_list_count;
  END IF;
  BEGIN
    PERFORM create_meeting_task(v_meeting_id, 'cross-org attempt', NULL, NULL, 'normal', 'section', NULL, NULL, NULL, NULL, 'cross-org decision', NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org create_meeting_task succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 5 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 5 PASSED: cross-org user denied visibility and creation on this org''s meeting';
END $$;

-- ─── 6. Duplicate active link prevention ───────────────────────────
DO $$
DECLARE v_task_id UUID; v_decision_id UUID;
BEGIN
  SELECT task_id, decision_id INTO v_task_id, v_decision_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  BEGIN
    PERFORM link_existing_task_to_meeting(v_task_id, (SELECT meeting_id FROM test_ids), v_decision_id, NULL, NULL);
    RAISE EXCEPTION 'TEST 6 FAILED: duplicate active link was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 6 PASSED: duplicate active link rejected';
END $$;

-- ─── 7. Meeting lifecycle independence (cancel meeting) ────────────
-- Uses the dedicated cancel_meeting_id fixture (not the main meeting
-- used by every other test) so this test's own state change doesn't
-- make a repeated run of this file fail elsewhere.
DO $$
DECLARE v_task_id UUID; v_meeting_id UUID; v_task_status_before TEXT;
BEGIN
  SELECT cancel_meeting_id INTO v_meeting_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);

  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R5 Test: cancellation-independence task') THEN
    SELECT (create_meeting_task(
      v_meeting_id, 'R5 Test: cancellation-independence task', NULL, NULL, 'normal', 'section', NULL, NULL, NULL,
      NULL, 'Decision for the cancellation test', NULL
    )).task_id INTO v_task_id;
  ELSE
    SELECT id INTO v_task_id FROM tasks WHERE title = 'R5 Test: cancellation-independence task';
  END IF;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;

  IF (SELECT status FROM meetings WHERE id = v_meeting_id) <> 'cancelled' THEN
    PERFORM cancel_meeting(v_meeting_id, 'test');
  END IF;

  IF (SELECT status FROM meetings WHERE id = v_meeting_id) <> 'cancelled' THEN
    RAISE EXCEPTION 'TEST 7 FAILED: meeting should be cancelled';
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 7 FAILED: task status changed as a side effect of meeting cancellation (% -> %)',
      v_task_status_before, (SELECT status FROM tasks WHERE id = v_task_id);
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: cancelling the meeting did not change the task status';
END $$;

-- ─── 8. Task lifecycle independence (complete task) ────────────────
DO $$
DECLARE v_task_id UUID; v_meeting_id UUID; v_meeting_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  SELECT status INTO v_meeting_status_before FROM meetings WHERE id = v_meeting_id;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT assignee FROM test_ids) || '"}', false);
  PERFORM update_task(v_task_id, p_status := 'open');
  PERFORM update_task(v_task_id, p_status := 'in_progress');
  PERFORM complete_task(v_task_id, 'done');

  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 8 FAILED: task should be completed';
  END IF;
  IF (SELECT status FROM meetings WHERE id = v_meeting_id) <> v_meeting_status_before THEN
    RAISE EXCEPTION 'TEST 8 FAILED: meeting status changed as a side effect of task completion';
  END IF;
  RAISE NOTICE 'TEST 8 PASSED: completing the task did not change the meeting status';
END $$;

-- ─── 9. Pagination is deterministic ─────────────────────────────────
DO $$
DECLARE v_meeting_id UUID; v_page1_task UUID; v_page1b_task UUID; v_page2_task UUID; v_total1 BIGINT; v_total2 BIGINT;
BEGIN
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  SELECT task_id, total_count INTO v_page1_task, v_total1 FROM list_meeting_tasks(v_meeting_id, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page1b_task, v_total1 FROM list_meeting_tasks(v_meeting_id, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page2_task, v_total2 FROM list_meeting_tasks(v_meeting_id, NULL, FALSE, 1, 1);
  IF v_page1_task IS DISTINCT FROM v_page1b_task THEN
    RAISE EXCEPTION 'TEST 9 FAILED: same offset returned different rows across calls';
  END IF;
  IF v_page1_task = v_page2_task THEN
    RAISE EXCEPTION 'TEST 9 FAILED: offset 0 and offset 1 returned the same row';
  END IF;
  IF v_total1 <> v_total2 OR v_total1 < 2 THEN
    RAISE EXCEPTION 'TEST 9 FAILED: total_count inconsistent across pages (% vs %)', v_total1, v_total2;
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: pagination is deterministic across repeated calls and offsets';
END $$;

-- ─── 10. Direct writes denied ────────────────────────────────────
DO $$
DECLARE
  v_task2_id UUID; v_meeting_id UUID; v_org_a UUID; v_creator UUID;
  v_rows_before INT; v_rows_after INT; v_insert_failed BOOLEAN := FALSE;
  v_decision_insert_failed BOOLEAN := FALSE;
BEGIN
  SELECT meeting_id, org_a, creator INTO v_meeting_id, v_org_a, v_creator FROM test_ids;
  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R5 Test: second supporting task';
  SELECT count(*) INTO v_rows_before FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (v_task2_id, 'meeting', gen_random_uuid(), v_org_a, v_creator);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_insert_failed := TRUE;
  END;
  IF NOT v_insert_failed THEN
    RAISE EXCEPTION 'TEST 10 FAILED: direct INSERT into task_links succeeded';
  END IF;

  BEGIN
    INSERT INTO meeting_decisions (meeting_id, organization_id, title, created_by)
    VALUES (v_meeting_id, v_org_a, 'sneaky decision', v_creator);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_decision_insert_failed := TRUE;
  END;
  IF NOT v_decision_insert_failed THEN
    RAISE EXCEPTION 'TEST 10 FAILED: direct INSERT into meeting_decisions succeeded';
  END IF;

  UPDATE task_links SET removed_at = NOW() WHERE task_id = v_task2_id;
  DELETE FROM task_links WHERE task_id = v_task2_id;

  SELECT count(*) INTO v_rows_after FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;
  IF v_rows_before <> v_rows_after THEN
    RAISE EXCEPTION 'TEST 10 FAILED: direct UPDATE/DELETE changed task_links rows';
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: direct writes to task_links and meeting_decisions all denied or no-op';
END $$;

-- ─── 11. Audit ────────────────────────────────────────────────────
-- audit_logs carries admin-only SELECT RLS for record_type='meeting'
-- (can_view_case_audit_record() has no 'meeting' branch — a
-- pre-existing scope of that helper, not something this milestone
-- changes) — none of this file's test users are org admins, so this
-- check runs as the connecting superuser (RESET ROLE bypasses RLS
-- entirely), matching how R3/R4's own manual verification confirmed
-- audit rows exist despite the same non-admin visibility gate.
RESET ROLE;
DO $$
DECLARE v_meeting_id UUID; v_linked_count INT; v_unlinked_count INT;
BEGIN
  SELECT meeting_id INTO v_meeting_id FROM test_ids;
  SELECT count(*) INTO v_linked_count FROM audit_logs WHERE action = 'task_linked' AND record_type = 'meeting' AND record_id = v_meeting_id;
  SELECT count(*) INTO v_unlinked_count FROM audit_logs WHERE action = 'task_unlinked' AND record_type = 'meeting' AND record_id = v_meeting_id;
  IF v_linked_count < 1 THEN
    RAISE EXCEPTION 'TEST 11 FAILED: no task_linked audit row found for this meeting';
  END IF;
  IF v_unlinked_count < 1 THEN
    RAISE EXCEPTION 'TEST 11 FAILED: no task_unlinked audit row found for this meeting';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: audit rows exist for both link and unlink actions, under record_type=meeting';
END $$;
SET ROLE authenticated;

-- ─── list_task_meeting_links sanity check (future Task Detail data source) ──
DO $$
DECLARE v_task_id UUID; v_row_count INT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_row_count FROM list_task_meeting_links(v_task_id);
  IF v_row_count < 1 THEN
    RAISE EXCEPTION 'TEST list_task_meeting_links FAILED: expected at least 1 linked meeting for this task';
  END IF;
  RAISE NOTICE 'TEST list_task_meeting_links PASSED: returns the meeting(s) this task is linked to';
END $$;

RESET ROLE;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS test_ids;

DO $$ BEGIN RAISE NOTICE 'ALL MEETING TASK INTEGRATION TESTS PASSED'; END $$;
