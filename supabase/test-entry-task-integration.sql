-- ============================================================
-- CorLink — Behavioral/RLS test: Entry ↔ Shared Tasks Integration
-- Companion to supabase/patch-entry-task-integration.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (two
-- organizations' worth of sections/users/entries, all with fixed
-- 'dddddddd-...'-prefixed UUIDs) and exercises every RPC under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation. Run this ONLY against a disposable/local test
-- database that already has the full migration chain through
-- patch-entry-task-integration.sql applied — NEVER against staging or
-- production. It is idempotent (fixtures use ON CONFLICT DO NOTHING,
-- and every RPC call that creates a Task is itself guarded by an
-- IF NOT EXISTS check on a fixed title — see docs/35/36 for the real
-- idempotency bugs that pattern was written to avoid) but not
-- side-effect-free: it creates real rows.
--
-- Requires (in the connecting session, once, before running this
-- file — a Supabase-platform-provided baseline in a real project,
-- only needs stubbing manually on a bare local Postgres instance):
--   GRANT USAGE ON SCHEMA public TO authenticated;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
--   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
--
-- "Existing Request/Meeting/Internal Collaboration integration still
-- works" (three of the required test categories) are deliberately NOT
-- reproduced inline here — they are fully covered, unmodified, by
-- running supabase/test-request-task-integration.sql, supabase/
-- test-meeting-task-integration.sql, and supabase/test-internal-
-- collaboration-task-integration.sql against this same database (all
-- three were re-run against a database with this patch applied as
-- part of this milestone's own verification and passed identically to
-- their pre-R7 runs — see docs/36).
--
-- inserted_at (clock_timestamp()-defaulted, NOT the random task_id/
-- link_id UUID columns) is what every "first/most recent row" lookup
-- below orders by — a lesson from R6's own test file, where ordering
-- by a random UUID column silently picked an arbitrary row instead of
-- true insertion order.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- Two orgs. Org D: entry_section (the org's designated Entry-staff
-- section — entry_sections row below), receiving_section (routed-to
-- section that does the responding work), outsider_section (unrelated
-- same-org section). Org E: otherorg_section (cross-org outsider).
-- Three Entries: entry1 (routed, assigned), entry2 (routed, sibling —
-- used for lifecycle-independence + pagination fixtures), entry3
-- (closed — business-rule + isolation testing).
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('dddddddd-0000-0000-0000-000000000001', 'R7 Test Org D', 'mcs', 'R7D'),
    ('dddddddd-0000-0000-0000-000000000002', 'R7 Test Org E', 'authority', 'R7E')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('dddddddd-0000-0000-0000-000000000010', 'R7 Test Command D', 'dddddddd-0000-0000-0000-000000000001'),
    ('dddddddd-0000-0000-0000-000000000011', 'R7 Test Command E', 'dddddddd-0000-0000-0000-000000000002')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('dddddddd-0000-0000-0000-000000000020', 'R7 Test Department D', 'dddddddd-0000-0000-0000-000000000010'),
    ('dddddddd-0000-0000-0000-000000000021', 'R7 Test Department E', 'dddddddd-0000-0000-0000-000000000011')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('dddddddd-0000-0000-0000-000000000030', 'R7 Entry Section',      'R7EN', 'dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000020'),
    ('dddddddd-0000-0000-0000-000000000031', 'R7 Receiving Section',  'R7RC', 'dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000020'),
    ('dddddddd-0000-0000-0000-000000000032', 'R7 Outsider Section',   'R7OS', 'dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000020'),
    ('dddddddd-0000-0000-0000-000000000040', 'R7 Other Org Section',  'R7XO', 'dddddddd-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000021')
  ON CONFLICT (id) DO NOTHING;

  -- Designate the Entry section explicitly — is_entry_staff() falls
  -- back to "any org member" only when entry_sections has zero rows
  -- for the org, which would make TEST 4 (unrelated same-org section
  -- denial) meaningless; this fixture matches how a real org actually
  -- configures Entry.
  INSERT INTO entry_sections (org_id, section_id)
  VALUES ('dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000030')
  ON CONFLICT DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('dddddddd-1111-0000-0000-000000000001', 'r7test-entrystaff@test.local'),
    ('dddddddd-1111-0000-0000-000000000002', 'r7test-receiving@test.local'),
    ('dddddddd-1111-0000-0000-000000000003', 'r7test-supervisor@test.local'),
    ('dddddddd-1111-0000-0000-000000000004', 'r7test-assignee@test.local'),
    ('dddddddd-1111-0000-0000-000000000005', 'r7test-outsider@test.local'),
    ('dddddddd-1111-0000-0000-000000000006', 'r7test-otherorg@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('dddddddd-1111-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 'R7T-SN001', 'R7Test EntryStaff',  'r7test-entrystaff@test.local', TRUE),
    ('dddddddd-1111-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000001', 'R7T-SN002', 'R7Test Receiving',   'r7test-receiving@test.local', TRUE),
    ('dddddddd-1111-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000001', 'R7T-SN003', 'R7Test Supervisor',  'r7test-supervisor@test.local', TRUE),
    ('dddddddd-1111-0000-0000-000000000004', 'dddddddd-0000-0000-0000-000000000001', 'R7T-SN004', 'R7Test Assignee',    'r7test-assignee@test.local', TRUE),
    ('dddddddd-1111-0000-0000-000000000005', 'dddddddd-0000-0000-0000-000000000001', 'R7T-SN005', 'R7Test Outsider',    'r7test-outsider@test.local', TRUE),
    ('dddddddd-1111-0000-0000-000000000006', 'dddddddd-0000-0000-0000-000000000002', 'R7T-SN006', 'R7Test OtherOrg',    'r7test-otherorg@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
    ('dddddddd-1111-0000-0000-000000000001', 'section', 'dddddddd-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('dddddddd-1111-0000-0000-000000000002', 'section', 'dddddddd-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('dddddddd-1111-0000-0000-000000000003', 'section', 'dddddddd-0000-0000-0000-000000000031', 'supervisor', TRUE, TRUE),
    ('dddddddd-1111-0000-0000-000000000004', 'section', 'dddddddd-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('dddddddd-1111-0000-0000-000000000005', 'section', 'dddddddd-0000-0000-0000-000000000032', 'staff', TRUE, TRUE),
    ('dddddddd-1111-0000-0000-000000000006', 'section', 'dddddddd-0000-0000-0000-000000000040', 'staff', TRUE, TRUE)
  ON CONFLICT DO NOTHING;

  -- entry1: routed, assigned — the main test entry.
  INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, status, assigned_to)
  VALUES (
    'dddddddd-2222-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 'email', 'public',
    'R7 Test Sender 1', 'R7 test entry 1 (routed)', 'body text',
    'dddddddd-1111-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000031', 'routed', 'dddddddd-1111-0000-0000-000000000004'
  ) ON CONFLICT (id) DO NOTHING;

  -- entry2: routed sibling, unassigned — isolation + lifecycle test.
  INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, status)
  VALUES (
    'dddddddd-2222-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000001', 'letter', 'public',
    'R7 Test Sender 2', 'R7 test entry 2 (routed sibling)', 'body text',
    'dddddddd-1111-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000031', 'routed'
  ) ON CONFLICT (id) DO NOTHING;

  -- entry3: CLOSED — closed-entry business rule test + isolation.
  INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, status)
  VALUES (
    'dddddddd-2222-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000001', 'in_person', 'public',
    'R7 Test Sender 3', 'R7 test entry 3 (closed)', 'body text',
    'dddddddd-1111-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000031', 'closed'
  ) ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'Fixtures ready.';
END $$;

CREATE TEMP TABLE test_ids AS SELECT
  'dddddddd-1111-0000-0000-000000000001'::uuid AS entry_staff,
  'dddddddd-1111-0000-0000-000000000002'::uuid AS receiving,
  'dddddddd-1111-0000-0000-000000000003'::uuid AS supervisor,
  'dddddddd-1111-0000-0000-000000000004'::uuid AS assignee,
  'dddddddd-1111-0000-0000-000000000005'::uuid AS outsider,
  'dddddddd-1111-0000-0000-000000000006'::uuid AS otherorg,
  'dddddddd-0000-0000-0000-000000000001'::uuid AS org_d,
  'dddddddd-0000-0000-0000-000000000031'::uuid AS receiving_section,
  'dddddddd-2222-0000-0000-000000000001'::uuid AS entry1,
  'dddddddd-2222-0000-0000-000000000002'::uuid AS entry2,
  'dddddddd-2222-0000-0000-000000000003'::uuid AS entry3_closed;

CREATE TEMP TABLE t1 (task_id UUID, link_id UUID, task_number TEXT, inserted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());

GRANT SELECT, INSERT, UPDATE ON test_ids, t1 TO authenticated;

SET ROLE authenticated;

-- ─── 1. Create Task ─────────────────────────────────────────────
-- Actor is `receiving` (the routed-to section's own staff), not
-- `entry_staff` — create_task() itself requires the actor to belong
-- to the owning_section it's given (unless super admin), and this
-- test deliberately gives the task an owning_section of
-- receiving_section to exercise that path realistically.
-- Idempotent (checked via a fixed title).
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R7 Test: gather supporting docs') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_entry_supporting_task(
      (SELECT entry1 FROM test_ids), 'R7 Test: gather supporting docs', 'desc',
      (SELECT receiving_section FROM test_ids), 'high', 'section', NULL, NULL,
      ARRAY[(SELECT assignee FROM test_ids)]
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'external_correspondence' AND tl.removed_at IS NULL
    WHERE t.title = 'R7 Test: gather supporting docs';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_active_link INT; v_active_assignment INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT count(*) INTO v_active_link FROM task_links WHERE id = v_link_id AND removed_at IS NULL AND module_key = 'external_correspondence';
  SELECT count(*) INTO v_active_assignment FROM task_assignments WHERE task_id = v_task_id AND is_active;
  IF v_task_id IS NULL OR v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_entry_supporting_task returned a null id';
  END IF;
  IF v_active_link <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active entry link, got %', v_active_link;
  END IF;
  IF v_active_assignment <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active assignment, got %', v_active_assignment;
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: authorized receiving-section worker created+linked a supporting task with an assignee';
END $$;

-- ─── 2. Link Task ───────────────────────────────────────────────
-- The receiving-section supervisor links a pre-existing task.
-- Idempotent (checked via a fixed title).
DO $$
DECLARE v_org_d UUID; v_task2_id UUID; v_link_id UUID;
BEGIN
  SELECT org_d INTO v_org_d FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT supervisor FROM test_ids) || '"}', false);

  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R7 Test: second supporting task';
  IF v_task2_id IS NULL THEN
    v_task2_id := create_task(v_org_d, 'R7 Test: second supporting task');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM task_links WHERE task_id = v_task2_id AND module_key = 'external_correspondence'
      AND record_id = (SELECT entry1 FROM test_ids) AND removed_at IS NULL
  ) THEN
    v_link_id := link_existing_task_to_entry(v_task2_id, (SELECT entry1 FROM test_ids));
    IF v_link_id IS NULL THEN
      RAISE EXCEPTION 'TEST 2 FAILED: link_existing_task_to_entry returned null';
    END IF;
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: link_existing_task_to_entry linked a pre-existing task';
END $$;

-- ─── 3. Unlink Task ─────────────────────────────────────────────
DO $$
DECLARE
  v_task_id UUID; v_link_id UUID; v_entry1 UUID;
  v_task_status_before TEXT; v_entry_status_before TEXT;
  v_removed_at TIMESTAMPTZ; v_row_count INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT entry1 INTO v_entry1 FROM test_ids;
  -- receiving, not entry_staff: entry_staff can MANAGE this link (via
  -- can_manage_entry_task_link) without necessarily being able to VIEW
  -- the task itself (task visibility is a separate predicate) — using
  -- an actor with full visibility here keeps this test's own
  -- before/after checks meaningful rather than vacuously RLS-filtered.
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_entry_status_before FROM external_correspondence WHERE id = v_entry1;

  PERFORM unlink_task_from_entry(v_link_id, 'test unlink');

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
  IF (SELECT status FROM external_correspondence WHERE id = v_entry1) <> v_entry_status_before THEN
    RAISE EXCEPTION 'TEST 3 FAILED: entry status changed on unlink';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: unlink soft-removes only, task/entry status untouched, history retained';
END $$;
-- Re-link so later tests still have an active link on t1's task.
DO $$
DECLARE v_task_id UUID; v_new_link_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  IF NOT EXISTS (
    SELECT 1 FROM task_links WHERE task_id = v_task_id AND module_key = 'external_correspondence'
      AND record_id = (SELECT entry1 FROM test_ids) AND removed_at IS NULL
  ) THEN
    v_new_link_id := link_existing_task_to_entry(v_task_id, (SELECT entry1 FROM test_ids));
    UPDATE t1 SET link_id = v_new_link_id WHERE task_id = v_task_id;
  END IF;
END $$;

-- ─── 4. Entry visibility (both directions) ─────────────────────
-- Task visible but not entry: assign TEST 1's task to outsider (now
-- visible via task_assignments) while outsider remains outside the
-- entry's own visibility grants.
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT outsider INTO v_outsider FROM test_ids;
  -- receiving, not entry_staff: assign_task() requires can_manage_task()
  -- (creator/active assignee/scoped supervisor), which entry_staff does
  -- not have on this task — same note as TEST 3/7 above.
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  PERFORM assign_task(v_task_id, v_outsider);
END $$;
DO $$
DECLARE v_task_id UUID; v_entry1 UUID; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT entry1 INTO v_entry1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'external_correspondence', v_entry1);
  IF NOT v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4 FAILED: newly-assigned outsider should now see the task';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4 FAILED: outsider should not see the link (can view task but not entry)';
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: user who can view the Task but not the Entry cannot see the link';
END $$;
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  PERFORM unassign_task(v_task_id, v_outsider);
END $$;

-- Entry visible but not task: a private task linked to entry1,
-- visible only to its own creator (entry_staff).
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT entry_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R7 Test: private task') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_entry_supporting_task(
      (SELECT entry1 FROM test_ids), 'R7 Test: private task', NULL, NULL, 'normal', 'private', NULL, NULL, NULL
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'external_correspondence' AND tl.removed_at IS NULL
    WHERE t.title = 'R7 Test: private task';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_entry1 UUID; v_can_view_entry BOOLEAN; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at DESC LIMIT 1;
  SELECT entry1 INTO v_entry1 FROM test_ids;
  -- outsider is same-org but NOT entry staff, not to_section, not
  -- assigned, not the logger — should not see entry1 at all either;
  -- use "receiving" instead (to_section member: genuinely sees the
  -- entry, but did not create this private task).
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  v_can_view_entry := can_view_entry(v_entry1);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'external_correspondence', v_entry1);
  IF NOT v_can_view_entry THEN
    RAISE EXCEPTION 'TEST 4B FAILED: receiving-section member should see entry1';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 4B FAILED: receiving-section member should not see a private task belonging to someone else';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 4B FAILED: receiving-section member should not see the link (can view entry but not task)';
  END IF;
  RAISE NOTICE 'TEST 4B PASSED: user who can view the Entry but not the Task cannot see the link';
END $$;

-- ─── 5. Cross-org denial ─────────────────────────────────────────
DO $$
DECLARE v_entry1 UUID; v_list_count INT; v_caps RECORD;
BEGIN
  SELECT entry1 INTO v_entry1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_entry_task_capabilities(v_entry1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user capabilities should be all-false, got %', v_caps;
  END IF;
  SELECT count(*) INTO v_list_count FROM list_entry_tasks(v_entry1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should enumerate 0 tasks, saw %', v_list_count;
  END IF;
  BEGIN
    PERFORM create_entry_supporting_task(v_entry1, 'cross-org attempt', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org create succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 5 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 5 PASSED: cross-org user cannot access or infer this entry''s supporting tasks';
END $$;

-- ─── 6. Cross-section (same-org, unrelated) denial ─────────────────
DO $$
DECLARE v_entry1 UUID; v_task_id UUID; v_list_count INT; v_caps RECORD;
BEGIN
  SELECT entry1 INTO v_entry1 FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_entry_task_capabilities(v_entry1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 6 FAILED: unrelated same-org section capabilities should be all-false, got %', v_caps;
  END IF;

  SELECT count(*) INTO v_list_count FROM list_entry_tasks(v_entry1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: unrelated section should enumerate 0 tasks, saw %', v_list_count;
  END IF;

  BEGIN
    PERFORM create_entry_supporting_task(v_entry1, 'sneaky', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 6 FAILED: unrelated section create succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM link_existing_task_to_entry(v_task_id, v_entry1);
    RAISE EXCEPTION 'TEST 6 FAILED: unrelated section link succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 6 PASSED: unrelated same-org section cannot create, link, or enumerate';
END $$;

-- ─── 7. Duplicate active link rejected ─────────────────────────────
-- receiving, not entry_staff: link_existing_task_to_entry() requires
-- can_manage_task() on the task side too, which entry_staff does not
-- have on this particular task (see TEST 3's note) — using an actor
-- who genuinely can manage the task keeps this exercising the
-- duplicate-link check itself, not an unrelated authorization failure.
DO $$
DECLARE v_task_id UUID; v_entry1 UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT entry1 INTO v_entry1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  BEGIN
    PERFORM link_existing_task_to_entry(v_task_id, v_entry1);
    RAISE EXCEPTION 'TEST 7 FAILED: duplicate active link was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 7 PASSED: duplicate active link rejected';
END $$;

-- ─── 8. Closed Entry restrictions ──────────────────────────────────
-- receiving, not entry_staff: entry3 is also routed to
-- receiving_section, so `receiving` can manage entry3 (via to_section
-- membership) AND manage TEST 1's task (as its creator) — needed so
-- the link-on-closed-entry attempt below actually exercises the
-- closed-status check rather than failing on an unrelated can_manage_
-- task() authorization gap first (see TEST 3/7's note).
DO $$
DECLARE v_entry3 UUID; v_task_id UUID; v_caps RECORD;
BEGIN
  SELECT entry3_closed INTO v_entry3 FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_entry_task_capabilities(v_entry3);
  IF NOT v_caps.can_view_tasks THEN
    RAISE EXCEPTION 'TEST 8 FAILED: receiving-section member should still be able to VIEW a closed entry''s (empty) task list';
  END IF;
  IF v_caps.can_create_task OR v_caps.can_link_existing THEN
    RAISE EXCEPTION 'TEST 8 FAILED: create/link must be blocked on a closed entry, got %', v_caps;
  END IF;
  IF NOT v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 8 FAILED: unlink should remain available on a closed entry (soft removal is not new work)';
  END IF;

  BEGIN
    PERFORM create_entry_supporting_task(v_entry3, 'sneaky on closed entry', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 8 FAILED: create succeeded on a closed entry';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 8 FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM link_existing_task_to_entry(v_task_id, v_entry3);
    RAISE EXCEPTION 'TEST 8 FAILED: link succeeded on a closed entry';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 8 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 8 PASSED: closed entry blocks create/link but not view/unlink';
END $$;

-- Also confirms sibling isolation: entry3 (closed, never linked) has
-- zero tasks even though entry1/entry2 do.
DO $$
DECLARE v_entry3 UUID; v_count INT;
BEGIN
  SELECT entry3_closed INTO v_entry3 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT entry_staff FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_count FROM list_entry_tasks(v_entry3);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 8B FAILED: closed, never-linked entry3 should show 0 tasks, saw %', v_count;
  END IF;
  RAISE NOTICE 'TEST 8B PASSED: sibling entry isolation — entry3 shows 0 tasks despite entry1 having several';
END $$;

-- ─── 9. Lifecycle independence (both directions) ────────────────────
-- Entry status change (route -> assign on entry2) does not change a
-- linked Task's status.
DO $$
DECLARE v_task2_id UUID; v_entry2 UUID; v_task_status_before TEXT;
BEGIN
  SELECT entry2 INTO v_entry2 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT supervisor FROM test_ids) || '"}', false);

  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R7 Test: entry2 lifecycle task') THEN
    SELECT task_id INTO v_task2_id FROM create_entry_supporting_task(
      v_entry2, 'R7 Test: entry2 lifecycle task', NULL, NULL, 'normal', 'section', NULL, NULL, NULL
    );
  ELSE
    SELECT id INTO v_task2_id FROM tasks WHERE title = 'R7 Test: entry2 lifecycle task';
  END IF;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task2_id;

  UPDATE external_correspondence SET assigned_to = (SELECT assignee FROM test_ids) WHERE id = v_entry2;

  IF (SELECT assigned_to FROM external_correspondence WHERE id = v_entry2) IS NULL THEN
    RAISE EXCEPTION 'TEST 9 FAILED: entry2 assignment update did not take effect (fixture/RLS problem, not the thing under test)';
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task2_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 9 FAILED: task status changed as a side effect of entry assignment (% -> %)',
      v_task_status_before, (SELECT status FROM tasks WHERE id = v_task2_id);
  END IF;
  RAISE NOTICE 'TEST 9 PASSED (direction 1): entry status/assignment changes do not change Task status';
END $$;

-- Task status change (complete) does not change Entry status.
DO $$
DECLARE v_task_id UUID; v_entry1 UUID; v_entry_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT entry1 INTO v_entry1 FROM test_ids;
  SELECT status INTO v_entry_status_before FROM external_correspondence WHERE id = v_entry1;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT assignee FROM test_ids) || '"}', false);
  -- Idempotent: a repeated run finds this task already completed.
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    PERFORM update_task(v_task_id, p_status := 'open');
    PERFORM update_task(v_task_id, p_status := 'in_progress');
    PERFORM complete_task(v_task_id, 'done');
  END IF;

  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 9B FAILED: task should be completed';
  END IF;
  IF (SELECT status FROM external_correspondence WHERE id = v_entry1) <> v_entry_status_before THEN
    RAISE EXCEPTION 'TEST 9B FAILED: entry status changed as a side effect of task completion';
  END IF;
  RAISE NOTICE 'TEST 9B PASSED (direction 2): completing the task did not change the entry''s status';
END $$;

-- ─── 10. Pagination is deterministic ────────────────────────────────
-- supervisor (not entry_staff): the supervisor branch of can_view_task()
-- covers every owning_section_id IS NULL task, plus any task owned by
-- a section they supervise — supervisor here sees all of entry1's
-- linked tasks, which entry_staff (who created none of them and isn't
-- assigned to any) mostly does not, so entry_staff alone would not
-- reliably see 2+ rows to paginate across.
DO $$
DECLARE v_entry1 UUID; v_page1_task UUID; v_page1b_task UUID; v_page2_task UUID; v_total1 BIGINT; v_total2 BIGINT;
BEGIN
  SELECT entry1 INTO v_entry1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT supervisor FROM test_ids) || '"}', false);
  SELECT task_id, total_count INTO v_page1_task, v_total1 FROM list_entry_tasks(v_entry1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page1b_task, v_total1 FROM list_entry_tasks(v_entry1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page2_task, v_total2 FROM list_entry_tasks(v_entry1, NULL, FALSE, 1, 1);
  IF v_page1_task IS DISTINCT FROM v_page1b_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: same offset returned different rows across calls';
  END IF;
  IF v_page1_task = v_page2_task THEN
    RAISE EXCEPTION 'TEST 10 FAILED: offset 0 and offset 1 returned the same row';
  END IF;
  IF v_total1 <> v_total2 OR v_total1 < 2 THEN
    RAISE EXCEPTION 'TEST 10 FAILED: total_count inconsistent across pages (% vs %)', v_total1, v_total2;
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: pagination is deterministic across repeated calls/offsets and stays scoped to one entry';
END $$;

-- ─── 11. Direct writes denied ────────────────────────────────────
-- Explicit actor (supervisor, task2's own creator from TEST 2) rather
-- than relying on whatever the previous test block left the session
-- role as — keeps the before/after task_links visibility checks
-- meaningful instead of RLS-filtered away for an unrelated reason.
DO $$
DECLARE
  v_task2_id UUID; v_org_d UUID; v_supervisor UUID;
  v_rows_before INT; v_rows_after INT; v_insert_failed BOOLEAN := FALSE;
BEGIN
  SELECT org_d, supervisor INTO v_org_d, v_supervisor FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || v_supervisor || '"}', false);
  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R7 Test: second supporting task';
  SELECT count(*) INTO v_rows_before FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (v_task2_id, 'external_correspondence', gen_random_uuid(), v_org_d, v_supervisor);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_insert_failed := TRUE;
  END;
  IF NOT v_insert_failed THEN
    RAISE EXCEPTION 'TEST 11 FAILED: direct INSERT into task_links (module_key=external_correspondence) succeeded';
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
-- can_view_case_audit_record() already has an external_correspondence
-- branch mirroring external_correspondence_select — checked as the
-- ordinary `authenticated` test user, no RLS bypass needed (same
-- happy situation as R6's internal_request).
DO $$
DECLARE v_entry1 UUID; v_linked_count INT; v_unlinked_count INT;
BEGIN
  SELECT entry1 INTO v_entry1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT entry_staff FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_linked_count FROM audit_logs WHERE action = 'task_linked' AND record_type = 'external_correspondence' AND record_id = v_entry1;
  SELECT count(*) INTO v_unlinked_count FROM audit_logs WHERE action = 'task_unlinked' AND record_type = 'external_correspondence' AND record_id = v_entry1;
  IF v_linked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_linked audit row found for entry1';
  END IF;
  IF v_unlinked_count < 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: no task_unlinked audit row found for entry1';
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: audit rows exist for both link and unlink actions, visible under record_type=external_correspondence without any RLS bypass';
END $$;

-- ─── list_task_entry_links sanity check (future Task Detail data source) ──
DO $$
DECLARE v_task_id UUID; v_row_count INT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT receiving FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_row_count FROM list_task_entry_links(v_task_id);
  IF v_row_count < 1 THEN
    RAISE EXCEPTION 'TEST list_task_entry_links FAILED: expected at least 1 linked entry for this task';
  END IF;
  RAISE NOTICE 'TEST list_task_entry_links PASSED: returns the entry (entries) this task is linked to';
END $$;

-- ─── Standalone task regression check ───────────────────────────────
DO $$
DECLARE v_org_d UUID; v_task_id UUID; v_link_count INT;
BEGIN
  SELECT org_d INTO v_org_d FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT entry_staff FROM test_ids) || '"}', false);
  v_task_id := create_task(v_org_d, 'R7 Test: standalone task, never linked');
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
-- Not exercised inline here — see docs/rollback/009-entry-task-
-- integration.md "What was actually tested" for the real end-to-end
-- dependency-detection / prerequisite-failure / clean-rollback /
-- reapply cycle run against a live instance, and docs/36 "Fresh
-- database verification" for the full-chain replay.

-- ─── 15/16/17. Existing Request/Meeting/Internal Collaboration
--     integration still work ────────────────────────────────────────
-- Deliberately not reproduced here — see the file header. Verified by
-- re-running supabase/test-request-task-integration.sql, supabase/
-- test-meeting-task-integration.sql, and supabase/test-internal-
-- collaboration-task-integration.sql end to end against this same
-- R7-patched database; all three passed identically to their pre-R7
-- runs.

RESET ROLE;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS test_ids;

DO $$ BEGIN RAISE NOTICE 'ALL ENTRY TASK INTEGRATION TESTS PASSED'; END $$;
