-- ============================================================
-- CorLink — Behavioral/RLS test: Requests ↔ Shared Tasks Integration
-- Companion to supabase/patch-request-task-integration.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (two
-- organizations' worth of sections/users/a request, all with fixed
-- 'aaaaaaaa-...'-prefixed UUIDs) and exercises every RPC under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation. Run this ONLY against a disposable/local test
-- database that already has the full migration chain through
-- patch-request-task-integration.sql applied — NEVER against staging
-- or production. It is idempotent (fixtures use ON CONFLICT DO
-- NOTHING) but not side-effect-free: it creates real rows.
--
-- Requires (in the connecting session, once, before running this
-- file — not part of this file itself, since these grants are a
-- Supabase-platform-provided baseline in a real project, and only
-- need to be stubbed manually on a bare local Postgres instance):
--   GRANT USAGE ON SCHEMA public TO authenticated;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
--   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
--
-- Every assertion below is a real DO $$ ... RAISE EXCEPTION $$ block —
-- this file hard-fails (aborts) at the first wrong answer, it does not
-- just print SELECT output for a human to eyeball. A clean run ends
-- with the final "ALL REQUEST-TASK INTEGRATION TESTS PASSED" notice.
--
-- Fixture ids are read from the test_ids temp table (populated in §0)
-- rather than psql :variables inside DO $$ blocks — psql does not
-- perform :variable substitution inside dollar-quoted strings, so
-- every ID lookup a DO block needs is a plain SELECT ... FROM test_ids
-- instead.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- Two orgs, one section each, a cross-org "sent" request from org A's
-- section to org B's section, and 5 users covering every role this
-- suite needs: creator, assignee, an uninvolved same-org outsider, a
-- cross-org (receiving-org) staff member, and a supervisor.
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Test Org A', 'mcs', 'TOA'),
    ('aaaaaaaa-0000-0000-0000-000000000002', 'Test Org B', 'authority', 'TOB')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000010', 'Test Command A', 'aaaaaaaa-0000-0000-0000-000000000001'),
    ('aaaaaaaa-0000-0000-0000-000000000011', 'Test Command B', 'aaaaaaaa-0000-0000-0000-000000000002')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000020', 'Test Department A', 'aaaaaaaa-0000-0000-0000-000000000010'),
    ('aaaaaaaa-0000-0000-0000-000000000021', 'Test Department B', 'aaaaaaaa-0000-0000-0000-000000000011')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000030', 'Test Section A1', 'TA1', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000020'),
    ('aaaaaaaa-0000-0000-0000-000000000031', 'Test Section A2', 'TA2', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000020'),
    ('aaaaaaaa-0000-0000-0000-000000000050', 'Test Section B1', 'TB1', 'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000021')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('aaaaaaaa-1111-0000-0000-000000000001', 'r4test-creator@test.local'),
    ('aaaaaaaa-1111-0000-0000-000000000002', 'r4test-assignee@test.local'),
    ('aaaaaaaa-1111-0000-0000-000000000003', 'r4test-outsider@test.local'),
    ('aaaaaaaa-1111-0000-0000-000000000004', 'r4test-otherorg@test.local'),
    ('aaaaaaaa-1111-0000-0000-000000000005', 'r4test-supervisor@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('aaaaaaaa-1111-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'R4T-SN001', 'R4Test Creator', 'r4test-creator@test.local', TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'R4T-SN002', 'R4Test Assignee', 'r4test-assignee@test.local', TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'R4T-SN003', 'R4Test Outsider', 'r4test-outsider@test.local', TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000002', 'R4T-SN004', 'R4Test OtherOrg', 'r4test-otherorg@test.local', TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000001', 'R4T-SN005', 'R4Test Supervisor', 'r4test-supervisor@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
    ('aaaaaaaa-1111-0000-0000-000000000001', 'section', 'aaaaaaaa-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000002', 'section', 'aaaaaaaa-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000003', 'section', 'aaaaaaaa-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000004', 'section', 'aaaaaaaa-0000-0000-0000-000000000050', 'staff', TRUE, TRUE),
    ('aaaaaaaa-1111-0000-0000-000000000005', 'section', 'aaaaaaaa-0000-0000-0000-000000000030', 'supervisor', TRUE, TRUE)
  ON CONFLICT DO NOTHING;

  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, subject, body, status)
  VALUES (
    'aaaaaaaa-2222-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
    'aaaaaaaa-0000-0000-0000-000000000030', 'aaaaaaaa-0000-0000-0000-000000000050',
    'aaaaaaaa-1111-0000-0000-000000000001', 'R4 test request', 'body text', 'sent'
  ) ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'Fixtures ready.';
END $$;

-- One-row lookup table so DO $$ blocks below can read fixture ids via
-- plain SQL instead of psql :variables (which are not substituted
-- inside dollar-quoted strings).
CREATE TEMP TABLE test_ids AS SELECT
  'aaaaaaaa-1111-0000-0000-000000000001'::uuid AS creator,
  'aaaaaaaa-1111-0000-0000-000000000002'::uuid AS assignee,
  'aaaaaaaa-1111-0000-0000-000000000003'::uuid AS outsider,
  'aaaaaaaa-1111-0000-0000-000000000004'::uuid AS otherorg,
  'aaaaaaaa-1111-0000-0000-000000000005'::uuid AS supervisor,
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS org_a,
  'aaaaaaaa-0000-0000-0000-000000000030'::uuid AS section_a1,
  'aaaaaaaa-2222-0000-0000-000000000001'::uuid AS req_id;

CREATE TEMP TABLE t1 (task_id UUID, link_id UUID);

-- Temp tables are only readable by their owner by default — grant the
-- authenticated role access before switching to it below, since every
-- assertion after this point runs as that role, not the connecting
-- superuser.
GRANT SELECT, INSERT, UPDATE ON test_ids, t1 TO authenticated;

SET ROLE authenticated;

-- ─── 1. Authorized Request worker can create and link a supporting Task ───
DO $$ BEGIN PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false); END $$;
INSERT INTO t1 (task_id, link_id)
SELECT task_id, link_id FROM create_request_supporting_task(
  (SELECT req_id FROM test_ids), 'R4 Test: follow up', 'desc', (SELECT section_a1 FROM test_ids),
  'high', 'section', NULL, NULL, ARRAY[(SELECT assignee FROM test_ids)]
);
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_active_link INT; v_active_assignment INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1;
  SELECT count(*) INTO v_active_link FROM task_links WHERE id = v_link_id AND removed_at IS NULL;
  SELECT count(*) INTO v_active_assignment FROM task_assignments WHERE task_id = v_task_id AND is_active;
  IF v_task_id IS NULL OR v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_request_supporting_task returned null task_id/link_id';
  END IF;
  IF v_active_link <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active link, got %', v_active_link;
  END IF;
  IF v_active_assignment <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active assignment, got %', v_active_assignment;
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: authorized worker created+linked a supporting task with an assignee';
END $$;

-- ─── 2. Unauthorized same-org user cannot create/link ─────────────
DO $$
DECLARE v_req_id UUID;
BEGIN
  SELECT req_id INTO v_req_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  BEGIN
    PERFORM create_request_supporting_task(v_req_id, 'sneaky');
    RAISE EXCEPTION 'TEST 2 FAILED: outsider create_request_supporting_task succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 2 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 2 PASSED: unauthorized same-org user rejected from create_request_supporting_task';
END $$;

-- ─── 3 & 4. Cross-org user cannot view/infer the link; can view Request but not Task ───
DO $$
DECLARE v_task_id UUID; v_req_id UUID; v_can_view_req BOOLEAN; v_can_view_task BOOLEAN; v_list_count INT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);
  v_can_view_req := can_view_request_or_response('request', v_req_id);
  v_can_view_task := can_view_task(v_task_id);
  SELECT count(*) INTO v_list_count FROM list_request_supporting_tasks(v_req_id);
  IF NOT v_can_view_req THEN
    RAISE EXCEPTION 'TEST 3/4 FAILED: cross-org to_section recipient should see the request';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 3/4 FAILED: cross-org user should NOT see a task in a different org';
  END IF;
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 3/4 FAILED: cross-org user should see 0 supporting tasks, saw %', v_list_count;
  END IF;
  RAISE NOTICE 'TEST 3/4 PASSED: cross-org user sees the request but not the task or the link';
END $$;

-- ─── 5. User who can view Task but not Request cannot see the link ───
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  PERFORM assign_task(v_task_id, v_outsider);
END $$;
DO $$
DECLARE v_task_id UUID; v_req_id UUID; v_can_view_task BOOLEAN; v_can_view_req BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_req := can_view_request_or_response('request', v_req_id);
  v_can_view_link := can_view_task_link(v_task_id, 'request', v_req_id);
  IF NOT v_can_view_task THEN
    RAISE EXCEPTION 'TEST 5 FAILED: newly-assigned outsider should now see the task';
  END IF;
  IF v_can_view_req THEN
    RAISE EXCEPTION 'TEST 5 FAILED: outsider still should not see the request';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 5 FAILED: outsider should not see the link (can view task but not request)';
  END IF;
  RAISE NOTICE 'TEST 5 PASSED: user who can view the Task but not the Request cannot see the link';
END $$;
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  PERFORM unassign_task(v_task_id, v_outsider);
END $$;

-- ─── 6. Duplicate active link rejected ─────────────────────────────
DO $$
DECLARE v_task_id UUID; v_req_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  BEGIN
    PERFORM link_existing_task_to_request(v_task_id, v_req_id);
    RAISE EXCEPTION 'TEST 6 FAILED: duplicate active link was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 6 PASSED: duplicate active link rejected';
END $$;

-- ─── 7. Unlink soft-removes without changing Task or Request status; history retained ───
DO $$
DECLARE
  v_task_id UUID; v_link_id UUID; v_req_id UUID;
  v_task_status_before TEXT; v_req_status_before TEXT;
  v_task_status_after TEXT; v_req_status_after TEXT;
  v_removed_at TIMESTAMPTZ; v_row_count INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_req_status_before FROM requests WHERE id = v_req_id;

  PERFORM unlink_task_from_request(v_link_id, 'test unlink');

  SELECT status INTO v_task_status_after FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_req_status_after FROM requests WHERE id = v_req_id;
  SELECT removed_at, count(*) OVER() INTO v_removed_at, v_row_count FROM task_links WHERE id = v_link_id;

  IF v_task_status_before <> v_task_status_after THEN
    RAISE EXCEPTION 'TEST 7 FAILED: task status changed on unlink (% -> %)', v_task_status_before, v_task_status_after;
  END IF;
  IF v_req_status_before <> v_req_status_after THEN
    RAISE EXCEPTION 'TEST 7 FAILED: request status changed on unlink (% -> %)', v_req_status_before, v_req_status_after;
  END IF;
  IF v_removed_at IS NULL THEN
    RAISE EXCEPTION 'TEST 7 FAILED: link row removed_at was not set';
  END IF;
  IF v_row_count <> 1 THEN
    RAISE EXCEPTION 'TEST 7 FAILED: link row was hard-deleted, history not retained';
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: unlink soft-removes only, task/request status untouched, history retained';
END $$;

-- Re-link (now that it's inactive) so tests 8/9 have an active link to observe.
DO $$
DECLARE v_task_id UUID; v_req_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  PERFORM link_existing_task_to_request(v_task_id, v_req_id);
END $$;

-- ─── 8 & 9. Request and Task lifecycles are independent ───────────
-- Captures each row's status immediately BEFORE the other row is
-- mutated and compares after, rather than asserting an absolute
-- value — the fixture request/task are reused (ON CONFLICT DO
-- NOTHING) across repeated runs of this file, so an earlier run's
-- final state (e.g. already 'cancelled') must not make a later run's
-- assertion here wrong.
DO $$
DECLARE v_task_id UUID; v_req_id UUID; v_req_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  SELECT status INTO v_req_status_before FROM requests WHERE id = v_req_id;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT assignee FROM test_ids) || '"}', false);
  PERFORM update_task(v_task_id, p_status := 'open');
  PERFORM update_task(v_task_id, p_status := 'in_progress');
  PERFORM complete_task(v_task_id, 'done');

  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 8 FAILED: task should be completed, is %', (SELECT status FROM tasks WHERE id = v_task_id);
  END IF;
  IF (SELECT status FROM requests WHERE id = v_req_id) <> v_req_status_before THEN
    RAISE EXCEPTION 'TEST 8 FAILED: request status changed as a side effect of task completion (% -> %)',
      v_req_status_before, (SELECT status FROM requests WHERE id = v_req_id);
  END IF;
  RAISE NOTICE 'TEST 8 PASSED: completing the task did not change the request status';
END $$;

DO $$
DECLARE v_task_id UUID; v_req_id UUID; v_task_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT req_id INTO v_req_id FROM test_ids;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT supervisor FROM test_ids) || '"}', false);
  UPDATE requests SET status = 'cancelled' WHERE id = v_req_id AND status IN ('sent','received','in_progress','overdue');

  IF (SELECT status FROM requests WHERE id = v_req_id) <> 'cancelled' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: request should be cancelled, is %', (SELECT status FROM requests WHERE id = v_req_id);
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 9 FAILED: task status changed as a side effect of request cancellation (% -> %)',
      v_task_status_before, (SELECT status FROM tasks WHERE id = v_task_id);
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: cancelling the request did not change the task status';
END $$;

-- ─── 10. Pagination is deterministic ────────────────────────────────
DO $$
DECLARE v_task2_id UUID; v_org_a UUID; v_section_a1 UUID; v_req_id UUID;
BEGIN
  SELECT org_a, section_a1, req_id INTO v_org_a, v_section_a1, v_req_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  v_task2_id := create_task(v_org_a, 'R4 Test: second supporting task', NULL, v_section_a1);
  PERFORM link_existing_task_to_request(v_task2_id, v_req_id);
END $$;
DO $$
DECLARE v_req_id UUID; v_page1_task UUID; v_page1b_task UUID; v_page2_task UUID; v_total1 BIGINT; v_total2 BIGINT;
BEGIN
  SELECT req_id INTO v_req_id FROM test_ids;
  SELECT task_id, total_count INTO v_page1_task, v_total1 FROM list_request_supporting_tasks(v_req_id, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page1b_task, v_total1 FROM list_request_supporting_tasks(v_req_id, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page2_task, v_total2 FROM list_request_supporting_tasks(v_req_id, NULL, FALSE, 1, 1);
  IF v_page1_task IS DISTINCT FROM v_page1b_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: same offset returned different rows across calls — not deterministic';
  END IF;
  IF v_page1_task = v_page2_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: offset 0 and offset 1 returned the same row';
  END IF;
  IF v_total1 <> v_total2 OR v_total1 < 2 THEN
    RAISE EXCEPTION 'TEST 10 FAILED: total_count inconsistent across pages (% vs %)', v_total1, v_total2;
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: pagination is deterministic across repeated calls and offsets';
END $$;

-- ─── 11. Direct INSERT/UPDATE/DELETE on task_links denied ──────────
DO $$
DECLARE
  v_task2_id UUID; v_req_id UUID; v_org_a UUID; v_creator UUID;
  v_rows_before INT; v_rows_after INT; v_insert_failed BOOLEAN := FALSE;
BEGIN
  SELECT req_id, org_a, creator INTO v_req_id, v_org_a, v_creator FROM test_ids;
  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R4 Test: second supporting task';
  SELECT count(*) INTO v_rows_before FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (v_task2_id, 'request', v_req_id, v_org_a, v_creator);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_insert_failed := TRUE;
  END;
  IF NOT v_insert_failed THEN
    RAISE EXCEPTION 'TEST 11 FAILED: direct INSERT into task_links succeeded';
  END IF;

  UPDATE task_links SET removed_at = NOW() WHERE task_id = v_task2_id;
  DELETE FROM task_links WHERE task_id = v_task2_id;

  SELECT count(*) INTO v_rows_after FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;
  IF v_rows_before <> v_rows_after THEN
    RAISE EXCEPTION 'TEST 11 FAILED: direct UPDATE/DELETE changed task_links rows (% -> %)', v_rows_before, v_rows_after;
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: direct INSERT/UPDATE/DELETE on task_links all denied or no-op';
END $$;

-- ─── 12. Audit rows created for link and unlink ────────────────────
DO $$
DECLARE v_req_id UUID; v_linked_count INT; v_unlinked_count INT;
BEGIN
  SELECT req_id INTO v_req_id FROM test_ids;
  SELECT count(*) INTO v_linked_count FROM audit_logs WHERE action = 'task_linked' AND record_id = v_req_id;
  SELECT count(*) INTO v_unlinked_count FROM audit_logs WHERE action = 'task_unlinked' AND record_id = v_req_id;
  IF v_linked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_linked audit row found';
  END IF;
  IF v_unlinked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_unlinked audit row found';
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: audit rows exist for both link and unlink actions';
END $$;

-- ─── 13. Existing standalone tasks remain valid (never linked) ────
DO $$
DECLARE v_standalone_id UUID; v_link_count INT; v_status TEXT; v_org_a UUID;
BEGIN
  SELECT org_a INTO v_org_a FROM test_ids;
  v_standalone_id := create_task(v_org_a, 'R4 Test: fully standalone task');
  SELECT count(*) INTO v_link_count FROM task_links WHERE task_id = v_standalone_id;
  SELECT status INTO v_status FROM tasks WHERE id = v_standalone_id;
  IF v_link_count <> 0 THEN
    RAISE EXCEPTION 'TEST 13 FAILED: a never-linked task unexpectedly has task_links rows';
  END IF;
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 13 FAILED: standalone task has unexpected status %', v_status;
  END IF;
  RAISE NOTICE 'TEST 13 PASSED: standalone tasks remain fully valid and independent of task_links';
END $$;

-- ─── 14. Existing Requests workflows remain valid (RLS/RPCs untouched) ───
DO $$
DECLARE v_can_view BOOLEAN; v_req_id UUID;
BEGIN
  SELECT req_id INTO v_req_id FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT creator FROM test_ids) || '"}', false);
  v_can_view := can_view_request_or_response('request', v_req_id);
  IF NOT v_can_view THEN
    RAISE EXCEPTION 'TEST 14 FAILED: creator can no longer view their own request via the untouched Requests RLS helper';
  END IF;
  RAISE NOTICE 'TEST 14 PASSED: existing Requests visibility (can_view_request_or_response) still works unmodified';
END $$;

RESET ROLE;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS test_ids;

DO $$ BEGIN RAISE NOTICE 'ALL REQUEST-TASK INTEGRATION TESTS PASSED'; END $$;
