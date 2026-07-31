-- ============================================================
-- CorLink — Behavioral/RLS test: Prisoner Letters ↔ Shared Tasks
-- Integration
-- Companion to supabase/patch-prisoner-letter-task-integration.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (three
-- organizations' worth of sections/users/letters, all with fixed
-- 'eeeeeeee-...'-prefixed UUIDs) and exercises every RPC under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation. Run this ONLY against a disposable/local test
-- database that already has the full migration chain through
-- patch-prisoner-letter-task-integration.sql applied — NEVER against
-- staging or production. It is idempotent (fixtures use ON CONFLICT DO
-- NOTHING, and every RPC call that creates a Task is itself guarded by
-- an IF NOT EXISTS check on a fixed title) but not side-effect-free:
-- it creates real rows.
--
-- Requires (in the connecting session, once, before running this
-- file — a Supabase-platform-provided baseline in a real project,
-- only needs stubbing manually on a bare local Postgres instance):
--   GRANT USAGE ON SCHEMA public TO authenticated;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
--   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
--
-- "Requests/Meetings/Internal Collaboration/Entry still work" (four of
-- the required test categories) are deliberately NOT reproduced inline
-- here — they are fully covered, unmodified, by running supabase/
-- test-request-task-integration.sql, supabase/test-meeting-task-
-- integration.sql, supabase/test-internal-collaboration-task-
-- integration.sql, and supabase/test-entry-task-integration.sql
-- against this same database (all four were re-run against a database
-- with this patch applied as part of this milestone's own
-- verification and passed identically to their pre-R8 runs — see
-- docs/37).
--
-- inserted_at (clock_timestamp()-defaulted, NOT the random task_id/
-- link_id UUID columns) is what every "first/most recent row" lookup
-- below orders by — a lesson from R6's own test file.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- Org P (MCS — the prison side, submits letters), Org Q (authority —
-- the destination side, replies), Org R (a THIRD, unrelated org — for
-- cross-org denial). mcs_staff (org P, flagged), authority_staff (org
-- Q, flagged, the letter's own assigned_to), non_staff (org Q, SAME
-- org as authority_staff, but NOT flagged — the confidentiality test),
-- otherorg (org R, flagged, but not party to any of these letters).
-- Three letters: letter1 (open/received, assigned), letter2 (open/
-- submitted sibling), letter3 (delivered — terminal-status business
-- rule + isolation test).
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('eeeeeeee-0000-0000-0000-000000000001', 'R8 Test Prison Org P', 'mcs', 'R8P'),
    ('eeeeeeee-0000-0000-0000-000000000002', 'R8 Test Authority Org Q', 'authority', 'R8Q'),
    ('eeeeeeee-0000-0000-0000-000000000003', 'R8 Test Other Org R', 'authority', 'R8R')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000010', 'R8 Test Command P', 'eeeeeeee-0000-0000-0000-000000000001'),
    ('eeeeeeee-0000-0000-0000-000000000011', 'R8 Test Command Q', 'eeeeeeee-0000-0000-0000-000000000002'),
    ('eeeeeeee-0000-0000-0000-000000000012', 'R8 Test Command R', 'eeeeeeee-0000-0000-0000-000000000003')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000020', 'R8 Test Department P', 'eeeeeeee-0000-0000-0000-000000000010'),
    ('eeeeeeee-0000-0000-0000-000000000021', 'R8 Test Department Q', 'eeeeeeee-0000-0000-0000-000000000011'),
    ('eeeeeeee-0000-0000-0000-000000000022', 'R8 Test Department R', 'eeeeeeee-0000-0000-0000-000000000012')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000030', 'R8 Section P', 'R8SP', 'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000020'),
    ('eeeeeeee-0000-0000-0000-000000000031', 'R8 Section Q',  'R8SQ', 'eeeeeeee-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000021'),
    ('eeeeeeee-0000-0000-0000-000000000032', 'R8 Section R',  'R8SR', 'eeeeeeee-0000-0000-0000-000000000003', 'eeeeeeee-0000-0000-0000-000000000022')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('eeeeeeee-1111-0000-0000-000000000001', 'r8test-mcsstaff@test.local'),
    ('eeeeeeee-1111-0000-0000-000000000002', 'r8test-authoritystaff@test.local'),
    ('eeeeeeee-1111-0000-0000-000000000003', 'r8test-nonstaff@test.local'),
    ('eeeeeeee-1111-0000-0000-000000000004', 'r8test-otherorg@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active, is_prisoner_letters_staff) VALUES
    ('eeeeeeee-1111-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'R8T-SN001', 'R8Test McsStaff',       'r8test-mcsstaff@test.local', TRUE, TRUE),
    ('eeeeeeee-1111-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002', 'R8T-SN002', 'R8Test AuthorityStaff', 'r8test-authoritystaff@test.local', TRUE, TRUE),
    ('eeeeeeee-1111-0000-0000-000000000003', 'eeeeeeee-0000-0000-0000-000000000002', 'R8T-SN003', 'R8Test NonStaff',       'r8test-nonstaff@test.local', TRUE, FALSE),
    ('eeeeeeee-1111-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000003', 'R8T-SN004', 'R8Test OtherOrg',       'r8test-otherorg@test.local', TRUE, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
    ('eeeeeeee-1111-0000-0000-000000000001', 'section', 'eeeeeeee-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('eeeeeeee-1111-0000-0000-000000000002', 'section', 'eeeeeeee-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('eeeeeeee-1111-0000-0000-000000000003', 'section', 'eeeeeeee-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('eeeeeeee-1111-0000-0000-000000000004', 'section', 'eeeeeeee-0000-0000-0000-000000000032', 'staff', TRUE, TRUE)
  ON CONFLICT DO NOTHING;

  -- letter1: open, received, assigned to authority_staff.
  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status, assigned_to, received_by, received_at)
  VALUES (
    'eeeeeeee-2222-0000-0000-000000000001', 'R8-INMATE-001', 'R8 Test Inmate 1',
    'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    'body text', 'eeeeeeee-1111-0000-0000-000000000001', 'received',
    'eeeeeeee-1111-0000-0000-000000000002', 'eeeeeeee-1111-0000-0000-000000000002', now()
  ) ON CONFLICT (id) DO NOTHING;

  -- letter2: open sibling, submitted, unassigned.
  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status)
  VALUES (
    'eeeeeeee-2222-0000-0000-000000000002', 'R8-INMATE-002', 'R8 Test Inmate 2',
    'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    'body text', 'eeeeeeee-1111-0000-0000-000000000001', 'submitted'
  ) ON CONFLICT (id) DO NOTHING;

  -- letter3: DELIVERED — terminal-status business rule + isolation.
  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status)
  VALUES (
    'eeeeeeee-2222-0000-0000-000000000003', 'R8-INMATE-003', 'R8 Test Inmate 3',
    'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    'body text', 'eeeeeeee-1111-0000-0000-000000000001', 'delivered'
  ) ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'Fixtures ready.';
END $$;

CREATE TEMP TABLE test_ids AS SELECT
  'eeeeeeee-1111-0000-0000-000000000001'::uuid AS mcs_staff,
  'eeeeeeee-1111-0000-0000-000000000002'::uuid AS authority_staff,
  'eeeeeeee-1111-0000-0000-000000000003'::uuid AS non_staff,
  'eeeeeeee-1111-0000-0000-000000000004'::uuid AS otherorg,
  'eeeeeeee-0000-0000-0000-000000000001'::uuid AS org_p,
  'eeeeeeee-2222-0000-0000-000000000001'::uuid AS letter1,
  'eeeeeeee-2222-0000-0000-000000000002'::uuid AS letter2,
  'eeeeeeee-2222-0000-0000-000000000003'::uuid AS letter3_delivered;

CREATE TEMP TABLE t1 (task_id UUID, link_id UUID, task_number TEXT, inserted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());

GRANT SELECT, INSERT, UPDATE ON test_ids, t1 TO authenticated;

SET ROLE authenticated;

-- ─── 1. Create Task ─────────────────────────────────────────────
-- authority_staff: the letter's own assigned_to, flagged staff at the
-- destination org — created task gets full visibility for later
-- assertions performed by the same actor.
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R8 Test: gather supporting docs') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_prisoner_letter_supporting_task(
      (SELECT letter1 FROM test_ids), 'R8 Test: gather supporting docs', 'desc',
      NULL, 'high', 'section', NULL, NULL,
      ARRAY[(SELECT authority_staff FROM test_ids)]
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'prisoner_letter' AND tl.removed_at IS NULL
    WHERE t.title = 'R8 Test: gather supporting docs';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_active_link INT; v_active_assignment INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT count(*) INTO v_active_link FROM task_links WHERE id = v_link_id AND removed_at IS NULL AND module_key = 'prisoner_letter';
  SELECT count(*) INTO v_active_assignment FROM task_assignments WHERE task_id = v_task_id AND is_active;
  IF v_task_id IS NULL OR v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_prisoner_letter_supporting_task returned a null id';
  END IF;
  IF v_active_link <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active prisoner_letter link, got %', v_active_link;
  END IF;
  IF v_active_assignment <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active assignment, got %', v_active_assignment;
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: authorized flagged staff at the destination org created+linked a supporting task with an assignee';
END $$;

-- ─── 2. Link Task ───────────────────────────────────────────────
-- mcs_staff (the submitting-org side, also flagged) links a
-- pre-existing task. Idempotent (checked via a fixed title).
DO $$
DECLARE v_org_p UUID; v_task2_id UUID; v_link_id UUID;
BEGIN
  SELECT org_p INTO v_org_p FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT mcs_staff FROM test_ids) || '"}', false);

  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R8 Test: second supporting task';
  IF v_task2_id IS NULL THEN
    v_task2_id := create_task(v_org_p, 'R8 Test: second supporting task');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM task_links WHERE task_id = v_task2_id AND module_key = 'prisoner_letter'
      AND record_id = (SELECT letter1 FROM test_ids) AND removed_at IS NULL
  ) THEN
    v_link_id := link_existing_task_to_prisoner_letter(v_task2_id, (SELECT letter1 FROM test_ids));
    IF v_link_id IS NULL THEN
      RAISE EXCEPTION 'TEST 2 FAILED: link_existing_task_to_prisoner_letter returned null';
    END IF;
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: link_existing_task_to_prisoner_letter linked a pre-existing task from the submitting-org side';
END $$;

-- ─── 3. Unlink Task ─────────────────────────────────────────────
DO $$
DECLARE
  v_task_id UUID; v_link_id UUID; v_letter1 UUID;
  v_task_status_before TEXT; v_letter_status_before TEXT;
  v_removed_at TIMESTAMPTZ; v_row_count INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_letter_status_before FROM prisoner_letters WHERE id = v_letter1;

  PERFORM unlink_task_from_prisoner_letter(v_link_id, 'test unlink');

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
  IF (SELECT status FROM prisoner_letters WHERE id = v_letter1) <> v_letter_status_before THEN
    RAISE EXCEPTION 'TEST 3 FAILED: letter status changed on unlink';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: unlink soft-removes only, task/letter status untouched, history retained';
END $$;
-- Re-link so later tests still have an active link on t1's task.
DO $$
DECLARE v_task_id UUID; v_new_link_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (
    SELECT 1 FROM task_links WHERE task_id = v_task_id AND module_key = 'prisoner_letter'
      AND record_id = (SELECT letter1 FROM test_ids) AND removed_at IS NULL
  ) THEN
    v_new_link_id := link_existing_task_to_prisoner_letter(v_task_id, (SELECT letter1 FROM test_ids));
    UPDATE t1 SET link_id = v_new_link_id WHERE task_id = v_task_id;
  END IF;
END $$;

-- ─── 4. Letter visibility (both directions) ────────────────────
-- Task visible but not letter: assign TEST 1's task to non_staff (now
-- visible via task_assignments) while non_staff remains outside the
-- letter's own confidentiality grant (same org as the task/letter, but
-- lacks is_prisoner_letters_staff — assign_task() itself requires the
-- assignee to share the task's organization, which otherorg — a
-- different org entirely — could never satisfy; non_staff is the
-- correct fixture for this specific direction).
DO $$
DECLARE v_task_id UUID; v_non_staff UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT non_staff INTO v_non_staff FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  PERFORM assign_task(v_task_id, v_non_staff);
END $$;
DO $$
DECLARE v_task_id UUID; v_letter1 UUID; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT non_staff FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'prisoner_letter', v_letter1);
  IF NOT v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4 FAILED: newly-assigned non_staff user should now see the task';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4 FAILED: non_staff user should not see the link (can view task but not letter)';
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: user who can view the Task but not the Prisoner Letter cannot see the link';
END $$;
DO $$
DECLARE v_task_id UUID; v_non_staff UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT non_staff INTO v_non_staff FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  PERFORM unassign_task(v_task_id, v_non_staff);
END $$;

-- Letter visible but not task: a private task linked to letter1,
-- visible only to its own creator (authority_staff) — mcs_staff can
-- see letter1 (party org, flagged) but not this private task.
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R8 Test: private task') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_prisoner_letter_supporting_task(
      (SELECT letter1 FROM test_ids), 'R8 Test: private task', NULL, NULL, 'normal', 'private', NULL, NULL, NULL
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'prisoner_letter' AND tl.removed_at IS NULL
    WHERE t.title = 'R8 Test: private task';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_letter1 UUID; v_can_view_letter BOOLEAN; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at DESC LIMIT 1;
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT mcs_staff FROM test_ids) || '"}', false);
  v_can_view_letter := can_view_prisoner_letter(v_letter1);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'prisoner_letter', v_letter1);
  IF NOT v_can_view_letter THEN
    RAISE EXCEPTION 'TEST 4B FAILED: mcs_staff (submitting-org flagged staff) should see letter1';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4B FAILED: mcs_staff should not see a private task belonging to someone else';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4B FAILED: mcs_staff should not see the link (can view letter but not task)';
  END IF;
  RAISE NOTICE 'TEST 4B PASSED: user who can view the Prisoner Letter but not the Task cannot see the link';
END $$;

-- ─── 5. Cross-org denial ─────────────────────────────────────────
DO $$
DECLARE v_letter1 UUID; v_list_count INT; v_caps RECORD;
BEGIN
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_prisoner_letter_task_capabilities(v_letter1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user capabilities should be all-false, got %', v_caps;
  END IF;
  SELECT count(*) INTO v_list_count FROM list_prisoner_letter_tasks(v_letter1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should enumerate 0 tasks, saw %', v_list_count;
  END IF;
  BEGIN
    PERFORM create_prisoner_letter_supporting_task(v_letter1, 'cross-org attempt', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org create succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 5 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 5 PASSED: cross-org user cannot access or infer this letter''s supporting tasks';
END $$;

-- ─── 6. Confidentiality (same-org, NOT flagged) ────────────────────
-- non_staff is a genuine member of org Q (the letter's own to_org),
-- but lacks the is_prisoner_letters_staff flag entirely — the
-- confidentiality gate this module exists for.
DO $$
DECLARE v_letter1 UUID; v_task_id UUID; v_list_count INT; v_caps RECORD; v_can_view_letter BOOLEAN;
BEGIN
  SELECT letter1 INTO v_letter1 FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT non_staff FROM test_ids) || '"}', false);

  v_can_view_letter := can_view_prisoner_letter(v_letter1);
  IF v_can_view_letter THEN
    RAISE EXCEPTION 'TEST 6 FAILED: non-flagged same-org user should not see the letter at all';
  END IF;

  SELECT * INTO v_caps FROM get_prisoner_letter_task_capabilities(v_letter1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 6 FAILED: non-flagged user capabilities should be all-false, got %', v_caps;
  END IF;

  SELECT count(*) INTO v_list_count FROM list_prisoner_letter_tasks(v_letter1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: non-flagged user should enumerate 0 tasks, saw %', v_list_count;
  END IF;

  BEGIN
    PERFORM create_prisoner_letter_supporting_task(v_letter1, 'sneaky', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 6 FAILED: non-flagged user create succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM link_existing_task_to_prisoner_letter(v_task_id, v_letter1);
    RAISE EXCEPTION 'TEST 6 FAILED: non-flagged user link succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 6 PASSED: confidentiality holds — a same-org, non-flagged user cannot view, create, link, or enumerate';
END $$;

-- ─── 7. Duplicate active link rejected ─────────────────────────────
DO $$
DECLARE v_task_id UUID; v_letter1 UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  BEGIN
    PERFORM link_existing_task_to_prisoner_letter(v_task_id, v_letter1);
    RAISE EXCEPTION 'TEST 7 FAILED: duplicate active link was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 7 PASSED: duplicate active link rejected';
END $$;

-- ─── 8. Delivered-letter restrictions ──────────────────────────────
DO $$
DECLARE v_letter3 UUID; v_task_id UUID; v_caps RECORD;
BEGIN
  SELECT letter3_delivered INTO v_letter3 FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_prisoner_letter_task_capabilities(v_letter3);
  IF NOT v_caps.can_view_tasks THEN
    RAISE EXCEPTION 'TEST 8 FAILED: flagged staff should still be able to VIEW a delivered letter''s (empty) task list';
  END IF;
  IF v_caps.can_create_task OR v_caps.can_link_existing THEN
    RAISE EXCEPTION 'TEST 8 FAILED: create/link must be blocked on a delivered letter, got %', v_caps;
  END IF;
  IF NOT v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 8 FAILED: unlink should remain available on a delivered letter (soft removal is not new work)';
  END IF;

  BEGIN
    PERFORM create_prisoner_letter_supporting_task(v_letter3, 'sneaky on delivered letter', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 8 FAILED: create succeeded on a delivered letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 8 FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM link_existing_task_to_prisoner_letter(v_task_id, v_letter3);
    RAISE EXCEPTION 'TEST 8 FAILED: link succeeded on a delivered letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 8 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 8 PASSED: delivered letter blocks create/link but not view/unlink';
END $$;

-- Also confirms sibling isolation: letter3 (delivered, never linked)
-- has zero tasks even though letter1 does.
DO $$
DECLARE v_letter3 UUID; v_count INT;
BEGIN
  SELECT letter3_delivered INTO v_letter3 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_count FROM list_prisoner_letter_tasks(v_letter3);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 8B FAILED: delivered, never-linked letter3 should show 0 tasks, saw %', v_count;
  END IF;
  RAISE NOTICE 'TEST 8B PASSED: sibling letter isolation — letter3 shows 0 tasks despite letter1 having several';
END $$;

-- ─── 9. Lifecycle independence (both directions) ────────────────────
-- Letter status change (submit -> received on letter2) does not
-- change a linked Task's status.
DO $$
DECLARE v_task2_id UUID; v_letter2 UUID; v_task_status_before TEXT;
BEGIN
  SELECT letter2 INTO v_letter2 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);

  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R8 Test: letter2 lifecycle task') THEN
    SELECT task_id INTO v_task2_id FROM create_prisoner_letter_supporting_task(
      v_letter2, 'R8 Test: letter2 lifecycle task', NULL, NULL, 'normal', 'section', NULL, NULL, NULL
    );
  ELSE
    SELECT id INTO v_task2_id FROM tasks WHERE title = 'R8 Test: letter2 lifecycle task';
  END IF;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task2_id;

  UPDATE prisoner_letters SET status = 'received', received_by = (SELECT authority_staff FROM test_ids), received_at = now() WHERE id = v_letter2 AND status = 'submitted';

  IF (SELECT status FROM tasks WHERE id = v_task2_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 9 FAILED: task status changed as a side effect of letter status change (% -> %)',
      v_task_status_before, (SELECT status FROM tasks WHERE id = v_task2_id);
  END IF;
  RAISE NOTICE 'TEST 9 PASSED (direction 1): letter status changes do not change Task status';
END $$;

-- Task status change (complete) does not change letter status.
DO $$
DECLARE v_task_id UUID; v_letter1 UUID; v_letter_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT letter1 INTO v_letter1 FROM test_ids;
  SELECT status INTO v_letter_status_before FROM prisoner_letters WHERE id = v_letter1;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  -- Idempotent: a repeated run finds this task already completed.
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    PERFORM update_task(v_task_id, p_status := 'open');
    PERFORM update_task(v_task_id, p_status := 'in_progress');
    PERFORM complete_task(v_task_id, 'done');
  END IF;

  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 9B FAILED: task should be completed';
  END IF;
  IF (SELECT status FROM prisoner_letters WHERE id = v_letter1) <> v_letter_status_before THEN
    RAISE EXCEPTION 'TEST 9B FAILED: letter status changed as a side effect of task completion';
  END IF;
  RAISE NOTICE 'TEST 9B PASSED (direction 2): completing the task did not change the letter''s status';
END $$;

-- ─── 10. Pagination is deterministic ────────────────────────────────
DO $$
DECLARE v_letter1 UUID; v_page1_task UUID; v_page1b_task UUID; v_page2_task UUID; v_total1 BIGINT; v_total2 BIGINT;
BEGIN
  SELECT letter1 INTO v_letter1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  SELECT task_id, total_count INTO v_page1_task, v_total1 FROM list_prisoner_letter_tasks(v_letter1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page1b_task, v_total1 FROM list_prisoner_letter_tasks(v_letter1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page2_task, v_total2 FROM list_prisoner_letter_tasks(v_letter1, NULL, FALSE, 1, 1);
  IF v_page1_task IS DISTINCT FROM v_page1b_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: same offset returned different rows across calls';
  END IF;
  IF v_page1_task = v_page2_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: offset 0 and offset 1 returned the same row';
  END IF;
  IF v_total1 <> v_total2 OR v_total1 < 2 THEN
    RAISE EXCEPTION 'TEST 10 FAILED: total_count inconsistent across pages (% vs %)', v_total1, v_total2;
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: pagination is deterministic across repeated calls/offsets and stays scoped to one letter';
END $$;

-- ─── 11. Direct writes denied ────────────────────────────────────
DO $$
DECLARE
  v_task2_id UUID; v_org_p UUID; v_mcs_staff UUID;
  v_rows_before INT; v_rows_after INT; v_insert_failed BOOLEAN := FALSE;
BEGIN
  SELECT org_p, mcs_staff INTO v_org_p, v_mcs_staff FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || v_mcs_staff || '"}', false);
  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R8 Test: second supporting task';
  SELECT count(*) INTO v_rows_before FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (v_task2_id, 'prisoner_letter', gen_random_uuid(), v_org_p, v_mcs_staff);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_insert_failed := TRUE;
  END;
  IF NOT v_insert_failed THEN
    RAISE EXCEPTION 'TEST 11 FAILED: direct INSERT into task_links (module_key=prisoner_letter) succeeded';
  END IF;

  UPDATE task_links SET removed_at = NOW() WHERE task_id = v_task2_id;
  DELETE FROM task_links WHERE task_id = v_task2_id;

  SELECT count(*) INTO v_rows_after FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;
  IF v_rows_before <> v_rows_after THEN
    RAISE EXCEPTION 'TEST 11 FAILED: direct UPDATE/DELETE changed task_links rows';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: direct INSERT/UPDATE/DELETE on task_links all denied or no-op';
END $$;

-- ─── 12. Audit ────────────────────────────────────────────────────
-- Unlike R6/R7's own record_type branches, can_view_case_audit_record()
-- has NO 'prisoner_letter' branch at all (a pre-existing gap, same
-- shape R5 found for 'meeting') — record_type='prisoner_letter' rows
-- are admin-only-visible by pre-existing design, unrelated to this
-- milestone. This check runs as the connecting superuser (RESET ROLE
-- bypasses RLS entirely), matching how R5's own manual verification
-- handled the identical situation.
RESET ROLE;
DO $$
DECLARE v_letter1 UUID; v_linked_count INT; v_unlinked_count INT;
BEGIN
  SELECT letter1 INTO v_letter1 FROM test_ids;
  SELECT count(*) INTO v_linked_count FROM audit_logs WHERE action = 'task_linked' AND record_type = 'prisoner_letter' AND record_id = v_letter1;
  SELECT count(*) INTO v_unlinked_count FROM audit_logs WHERE action = 'task_unlinked' AND record_type = 'prisoner_letter' AND record_id = v_letter1;
  IF v_linked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_linked audit row found for letter1';
  END IF;
  IF v_unlinked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_unlinked audit row found for letter1';
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: audit rows exist for both link and unlink actions (checked via superuser bypass — record_type=prisoner_letter has no can_view_case_audit_record() branch, a pre-existing gap documented in docs/37, not introduced by this milestone)';
END $$;
SET ROLE authenticated;

-- ─── list_task_prisoner_letter_links sanity check (future Task Detail data source) ──
DO $$
DECLARE v_task_id UUID; v_row_count INT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT authority_staff FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_row_count FROM list_task_prisoner_letter_links(v_task_id);
  IF v_row_count < 1 THEN
    RAISE EXCEPTION 'TEST list_task_prisoner_letter_links FAILED: expected at least 1 linked letter for this task';
  END IF;
  RAISE NOTICE 'TEST list_task_prisoner_letter_links PASSED: returns the letter(s) this task is linked to';
END $$;

-- ─── Standalone task regression check ───────────────────────────────
DO $$
DECLARE v_org_p UUID; v_task_id UUID; v_link_count INT;
BEGIN
  SELECT org_p INTO v_org_p FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT mcs_staff FROM test_ids) || '"}', false);
  v_task_id := create_task(v_org_p, 'R8 Test: standalone task, never linked');
  SELECT count(*) INTO v_link_count FROM task_links WHERE task_id = v_task_id;
  IF v_link_count <> 0 THEN
    RAISE EXCEPTION 'TEST standalone FAILED: a brand-new standalone task should have 0 task_links rows';
  END IF;
  IF NOT can_view_task(v_task_id) THEN
    RAISE EXCEPTION 'TEST standalone FAILED: standalone task should be visible to its own creator';
  END IF;
  RAISE NOTICE 'TEST standalone PASSED: standalone tasks remain fully valid and independent of task_links';
END $$;

-- ─── 13/14. Rollback / migration replay ────────────────────────────
-- Not exercised inline here — see docs/rollback/010-prisoner-letter-
-- task-integration.md "What was actually tested" for the real
-- end-to-end dependency-detection / prerequisite-failure / clean-
-- rollback / reapply cycle run against a live instance, and docs/37
-- "Fresh database verification" for the full-chain replay.

-- ─── 15/16/17/18. Requests/Meetings/Internal Collaboration/Entry
--     integration still work ────────────────────────────────────────
-- Deliberately not reproduced here — see the file header. Verified by
-- re-running supabase/test-request-task-integration.sql, supabase/
-- test-meeting-task-integration.sql, supabase/test-internal-
-- collaboration-task-integration.sql, and supabase/test-entry-task-
-- integration.sql end to end against this same R8-patched database;
-- all four passed identically to their pre-R8 runs.

RESET ROLE;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS test_ids;

DO $$ BEGIN RAISE NOTICE 'ALL PRISONER LETTER TASK INTEGRATION TESTS PASSED'; END $$;
