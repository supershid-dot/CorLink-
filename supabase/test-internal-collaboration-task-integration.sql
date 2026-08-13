-- ============================================================
-- CorLink — Behavioral/RLS test: Internal Collaboration ↔ Shared
-- Tasks Integration
-- Companion to supabase/patch-internal-collaboration-task-integration.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (two
-- organizations' worth of sections/users, a parent Request, a parent
-- Entry, and four internal_requests threads, all with fixed
-- 'cccccccc-...'-prefixed UUIDs) and exercises every RPC under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation. Run this ONLY against a disposable/local test
-- database that already has the full migration chain through
-- patch-internal-collaboration-task-integration.sql applied — NEVER
-- against staging or production. It is idempotent (fixtures use
-- ON CONFLICT DO NOTHING) but not side-effect-free: it creates real
-- rows.
--
-- Requires (in the connecting session, once, before running this
-- file — a Supabase-platform-provided baseline in a real project,
-- only needs stubbing manually on a bare local Postgres instance):
--   GRANT USAGE ON SCHEMA public TO authenticated;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
--   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
--
-- "Request integration still works" / "Meeting integration still
-- works" (two of the required test categories) are deliberately NOT
-- reproduced inline here — they are fully covered, unmodified, by
-- running supabase/test-request-task-integration.sql and supabase/
-- test-meeting-task-integration.sql against this same database (both
-- were re-run against a database with this patch applied as part of
-- this milestone's own verification and passed identically to their
-- pre-R6 runs — see docs/35). Reproducing their fixtures/assertions a
-- second time here would just be duplication.
--
-- Fixture ids are read from the test_ids temp table (populated in §0)
-- rather than psql :variables inside DO $$ blocks — psql does not
-- perform :variable substitution inside dollar-quoted strings. A clean
-- run ends with the final "ALL INTERNAL COLLABORATION TASK
-- INTEGRATION TESTS PASSED" notice.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- Two orgs. Org C: section_case_owner (the case-handling section that
-- starts each loop-in — this is the internal_requests.from_section on
-- every thread below), section_helper (the looped-in/receiving section
-- that does the actual supporting work — internal_requests.to_section),
-- section_outsider (an unrelated same-org section). Org D:
-- section_requester (the other org party to the parent Request) and
-- section_otherorg (a cross-org outsider). One parent Request (org D ->
-- org C), one parent Entry (org C only), and four internal_requests
-- threads: three on the Request (thread1 open/in_progress, thread2
-- open/received, thread3 closed — for isolation + closed-thread
-- business-rule testing) and one on the Entry (thread4).
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('cccccccc-0000-0000-0000-000000000001', 'R6 Test Org C', 'mcs', 'R6C'),
    ('cccccccc-0000-0000-0000-000000000002', 'R6 Test Org D', 'authority', 'R6D')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('cccccccc-0000-0000-0000-000000000010', 'R6 Test Command C', 'cccccccc-0000-0000-0000-000000000001'),
    ('cccccccc-0000-0000-0000-000000000011', 'R6 Test Command D', 'cccccccc-0000-0000-0000-000000000002')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('cccccccc-0000-0000-0000-000000000020', 'R6 Test Department C', 'cccccccc-0000-0000-0000-000000000010'),
    ('cccccccc-0000-0000-0000-000000000021', 'R6 Test Department D', 'cccccccc-0000-0000-0000-000000000011')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('cccccccc-0000-0000-0000-000000000030', 'R6 Case Owner Section',  'R6CO', 'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000020'),
    ('cccccccc-0000-0000-0000-000000000031', 'R6 Helper Section',      'R6HP', 'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000020'),
    ('cccccccc-0000-0000-0000-000000000032', 'R6 Outsider Section',    'R6OS', 'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000020'),
    ('cccccccc-0000-0000-0000-000000000040', 'R6 Other Org Section',   'R6XO', 'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000021'),
    ('cccccccc-0000-0000-0000-000000000041', 'R6 Requester Section',   'R6RQ', 'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000021')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('cccccccc-1111-0000-0000-000000000001', 'r6test-caseowner@test.local'),
    ('cccccccc-1111-0000-0000-000000000002', 'r6test-helperstaff@test.local'),
    ('cccccccc-1111-0000-0000-000000000003', 'r6test-helpersupervisor@test.local'),
    ('cccccccc-1111-0000-0000-000000000004', 'r6test-assignee@test.local'),
    ('cccccccc-1111-0000-0000-000000000005', 'r6test-outsider@test.local'),
    ('cccccccc-1111-0000-0000-000000000006', 'r6test-otherorg@test.local'),
    ('cccccccc-1111-0000-0000-000000000007', 'r6test-requester@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('cccccccc-1111-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'R6T-SN001', 'R6Test CaseOwner',       'r6test-caseowner@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001', 'R6T-SN002', 'R6Test HelperStaff',     'r6test-helperstaff@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000001', 'R6T-SN003', 'R6Test HelperSupervisor','r6test-helpersupervisor@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000004', 'cccccccc-0000-0000-0000-000000000001', 'R6T-SN004', 'R6Test Assignee',        'r6test-assignee@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000005', 'cccccccc-0000-0000-0000-000000000001', 'R6T-SN005', 'R6Test Outsider',        'r6test-outsider@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000006', 'cccccccc-0000-0000-0000-000000000002', 'R6T-SN006', 'R6Test OtherOrg',        'r6test-otherorg@test.local', TRUE),
    ('cccccccc-1111-0000-0000-000000000007', 'cccccccc-0000-0000-0000-000000000002', 'R6T-SN007', 'R6Test Requester',       'r6test-requester@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- assignee (004) and outsider (005) are BOTH members of
  -- section_outsider, deliberately NOT section_helper — isolates the
  -- can_manage_internal_collab_task_link() `ir.assigned_to = auth.uid()`
  -- branch (TEST 3) from plain to_section membership (assignee should
  -- still manage, purely via being the assigned user; outsider, who is
  -- not assigned to anything, should not — TEST 4).
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
    ('cccccccc-1111-0000-0000-000000000001', 'section', 'cccccccc-0000-0000-0000-000000000030', 'staff', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000002', 'section', 'cccccccc-0000-0000-0000-000000000031', 'staff', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000003', 'section', 'cccccccc-0000-0000-0000-000000000031', 'supervisor', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000004', 'section', 'cccccccc-0000-0000-0000-000000000032', 'staff', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000005', 'section', 'cccccccc-0000-0000-0000-000000000032', 'staff', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000006', 'section', 'cccccccc-0000-0000-0000-000000000040', 'staff', TRUE, TRUE),
    ('cccccccc-1111-0000-0000-000000000007', 'section', 'cccccccc-0000-0000-0000-000000000041', 'staff', TRUE, TRUE)
  ON CONFLICT DO NOTHING;

  -- Parent Request: org D asks org C's case-owner section to handle it.
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, subject, body, status)
  VALUES (
    'cccccccc-2222-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000041', 'cccccccc-0000-0000-0000-000000000030',
    'cccccccc-1111-0000-0000-000000000007', 'R6 test request', 'body text', 'sent'
  ) ON CONFLICT (id) DO NOTHING;

  -- Parent Entry: logged directly against org C.
  INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, status)
  VALUES (
    'cccccccc-4444-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000001', 'email', 'public', 'R6 Test Sender', 'R6 test entry', 'body text',
    'cccccccc-1111-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000030', 'routed'
  ) ON CONFLICT (id) DO NOTHING;

  -- Thread 1: request-hosted, open, assigned (assignee, not a
  -- section_helper member) — the main thread most tests below use.
  INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status, received_by, received_at, assigned_to)
  VALUES (
    'cccccccc-3333-0000-0000-000000000001', 'cccccccc-2222-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000030', 'cccccccc-0000-0000-0000-000000000031',
    'cccccccc-1111-0000-0000-000000000001', 'R6 test thread 1 (open)', 'need your help', 'in_progress',
    'cccccccc-1111-0000-0000-000000000002', now(), 'cccccccc-1111-0000-0000-000000000004'
  ) ON CONFLICT (id) DO NOTHING;

  -- Thread 2: request-hosted sibling, open, unassigned — isolation test.
  INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
  VALUES (
    'cccccccc-3333-0000-0000-000000000002', 'cccccccc-2222-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000030', 'cccccccc-0000-0000-0000-000000000031',
    'cccccccc-1111-0000-0000-000000000001', 'R6 test thread 2 (open sibling)', 'a second, unrelated ask', 'received'
  ) ON CONFLICT (id) DO NOTHING;

  -- Thread 3: request-hosted sibling, CLOSED — closed-thread business
  -- rule test (create/link blocked, unlink still allowed) + isolation.
  INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
  VALUES (
    'cccccccc-3333-0000-0000-000000000003', 'cccccccc-2222-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000030', 'cccccccc-0000-0000-0000-000000000031',
    'cccccccc-1111-0000-0000-000000000001', 'R6 test thread 3 (closed)', 'already resolved', 'closed'
  ) ON CONFLICT (id) DO NOTHING;

  -- Thread 4: entry-hosted — parent-type/parent-id navigation metadata test.
  INSERT INTO internal_requests (id, parent_entry_id, from_section_id, to_section_id, created_by, subject, body, status, assigned_to)
  VALUES (
    'cccccccc-3333-0000-0000-000000000004', 'cccccccc-4444-0000-0000-000000000001',
    'cccccccc-0000-0000-0000-000000000030', 'cccccccc-0000-0000-0000-000000000031',
    'cccccccc-1111-0000-0000-000000000001', 'R6 test thread 4 (entry-hosted)', 'entry-side ask', 'in_progress',
    'cccccccc-1111-0000-0000-000000000002'
  ) ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'Fixtures ready.';
END $$;

CREATE TEMP TABLE test_ids AS SELECT
  'cccccccc-1111-0000-0000-000000000001'::uuid AS case_owner,
  'cccccccc-1111-0000-0000-000000000002'::uuid AS helper_staff,
  'cccccccc-1111-0000-0000-000000000003'::uuid AS helper_supervisor,
  'cccccccc-1111-0000-0000-000000000004'::uuid AS assignee,
  'cccccccc-1111-0000-0000-000000000005'::uuid AS outsider,
  'cccccccc-1111-0000-0000-000000000006'::uuid AS otherorg,
  'cccccccc-1111-0000-0000-000000000007'::uuid AS requester,
  'cccccccc-0000-0000-0000-000000000001'::uuid AS org_c,
  'cccccccc-0000-0000-0000-000000000030'::uuid AS section_case_owner,
  'cccccccc-0000-0000-0000-000000000031'::uuid AS section_helper,
  'cccccccc-2222-0000-0000-000000000001'::uuid AS parent_request_id,
  'cccccccc-4444-0000-0000-000000000001'::uuid AS parent_entry_id,
  'cccccccc-3333-0000-0000-000000000001'::uuid AS thread1,
  'cccccccc-3333-0000-0000-000000000002'::uuid AS thread2,
  'cccccccc-3333-0000-0000-000000000003'::uuid AS thread3_closed,
  'cccccccc-3333-0000-0000-000000000004'::uuid AS thread4_entry;

-- inserted_at is a plain insertion-order marker — task_id/link_id are
-- random UUIDs, so "the first/most recent row inserted" must never be
-- found via ORDER BY task_id (that would sort by randomness, not
-- insertion order); every lookup below orders by this column instead.
-- clock_timestamp() (not now()/statement time) so consecutive INSERTs
-- within the same statement still get distinct, strictly increasing
-- values.
CREATE TEMP TABLE t1 (task_id UUID, link_id UUID, task_number TEXT, inserted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());

-- Temp tables are only readable by their owner by default — grant the
-- authenticated role access before switching to it below.
GRANT SELECT, INSERT, UPDATE ON test_ids, t1 TO authenticated;

SET ROLE authenticated;

-- ─── 1. Authorized receiving-section worker creates a supporting task ──
-- Idempotent (checked via a fixed title): re-running this file must
-- not keep creating new tasks/links each time.
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R6 Test: gather supporting info') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_internal_collaboration_supporting_task(
      (SELECT thread1 FROM test_ids), 'R6 Test: gather supporting info', 'desc',
      (SELECT section_helper FROM test_ids), 'high', 'section', NULL, NULL,
      ARRAY[(SELECT assignee FROM test_ids)]
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'internal_request' AND tl.removed_at IS NULL
    WHERE t.title = 'R6 Test: gather supporting info';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_active_link INT; v_active_assignment INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT count(*) INTO v_active_link FROM task_links WHERE id = v_link_id AND removed_at IS NULL AND module_key = 'internal_request';
  SELECT count(*) INTO v_active_assignment FROM task_assignments WHERE task_id = v_task_id AND is_active;
  IF v_task_id IS NULL OR v_link_id IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_internal_collaboration_supporting_task returned a null id';
  END IF;
  IF v_active_link <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active internal_request link, got %', v_active_link;
  END IF;
  IF v_active_assignment <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 1 active assignment, got %', v_active_assignment;
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: authorized receiving-section worker (helper_staff) created+linked a supporting task with an assignee';
END $$;

-- ─── 2. Sender-side worker can act only when existing rules permit ──
-- Per docs/35's authorization matrix, from_section (the asking/case-
-- owner side) is NOT granted manage authority — repository evidence
-- (js/views/request-detail.js's own action gating) never lets the
-- asking side manage ongoing work on a loop-in thread beyond creating
-- it. case_owner (from_section, and the thread's own creator) must be
-- rejected here.
DO $$
DECLARE v_thread1 UUID;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT case_owner FROM test_ids) || '"}', false);
  BEGIN
    PERFORM create_internal_collaboration_supporting_task(v_thread1, 'sneaky', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 2 FAILED: sender-side (from_section) creator was able to create a supporting task';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 2 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 2 PASSED: sender-side worker (from_section, even the thread''s own creator) rejected from creating supporting work, matching the documented authorization matrix';
END $$;

-- ─── 3. Current assignee can create/link when permitted ────────────
-- assignee is a member of section_outsider, NOT section_helper — the
-- ONLY reason they should be allowed to manage thread1 is the
-- ir.assigned_to = auth.uid() branch, isolated from to_section
-- membership entirely.
-- Idempotent (checked via a fixed title): re-running this file must
-- not keep creating new tasks each time.
DO $$
DECLARE v_org_c UUID; v_task2_id UUID; v_link_id UUID;
BEGIN
  SELECT org_c INTO v_org_c FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT assignee FROM test_ids) || '"}', false);

  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R6 Test: assignee-created task';
  IF v_task2_id IS NULL THEN
    v_task2_id := create_task(v_org_c, 'R6 Test: assignee-created task');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM task_links WHERE task_id = v_task2_id AND module_key = 'internal_request'
      AND record_id = (SELECT thread1 FROM test_ids) AND removed_at IS NULL
  ) THEN
    v_link_id := link_existing_task_to_internal_collaboration(v_task2_id, (SELECT thread1 FROM test_ids));
    IF v_link_id IS NULL THEN
      RAISE EXCEPTION 'TEST 3 FAILED: link_existing_task_to_internal_collaboration returned null for the assigned user';
    END IF;
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: current assignee (not a to_section member) can create and link a supporting task via the assigned_to branch alone';
END $$;

-- ─── 4. Unrelated same-org section cannot create, link, or enumerate ──
DO $$
DECLARE v_thread1 UUID; v_task_id UUID; v_list_count INT; v_caps RECORD;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  SELECT task_id INTO v_task_id FROM t1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_internal_collaboration_task_capabilities(v_thread1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 4 FAILED: outsider capabilities should be all-false, got %', v_caps;
  END IF;

  SELECT count(*) INTO v_list_count FROM list_internal_collaboration_tasks(v_thread1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 4 FAILED: outsider should enumerate 0 tasks on a thread they cannot see, saw %', v_list_count;
  END IF;

  BEGIN
    PERFORM create_internal_collaboration_supporting_task(v_thread1, 'sneaky2', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 4 FAILED: outsider create_internal_collaboration_supporting_task succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 4 FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM link_existing_task_to_internal_collaboration(v_task_id, v_thread1);
    RAISE EXCEPTION 'TEST 4 FAILED: outsider link_existing_task_to_internal_collaboration succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 4 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 4 PASSED: unrelated same-org section cannot create, link, or enumerate';
END $$;

-- ─── 5. Cross-org user cannot access or infer links ────────────────
DO $$
DECLARE v_thread1 UUID; v_list_count INT; v_caps RECORD;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);

  SELECT * INTO v_caps FROM get_internal_collaboration_task_capabilities(v_thread1);
  IF v_caps.can_view_tasks OR v_caps.can_create_task OR v_caps.can_link_existing OR v_caps.can_unlink THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user capabilities should be all-false, got %', v_caps;
  END IF;
  SELECT count(*) INTO v_list_count FROM list_internal_collaboration_tasks(v_thread1);
  IF v_list_count <> 0 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org user should enumerate 0 tasks, saw %', v_list_count;
  END IF;
  BEGIN
    PERFORM create_internal_collaboration_supporting_task(v_thread1, 'cross-org attempt', NULL, NULL, 'normal', 'section', NULL, NULL, NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: cross-org create succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 5 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 5 PASSED: cross-org user cannot access or infer this thread''s supporting tasks';
END $$;

-- ─── 6. User who sees Task but not thread cannot see the link ─────
-- Temporarily assign TEST 1's task to outsider (now they can view the
-- TASK) while outsider remains unable to view thread1 itself.
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  PERFORM assign_task(v_task_id, v_outsider);
END $$;
DO $$
DECLARE v_task_id UUID; v_thread1 UUID; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'internal_request', v_thread1);
  IF NOT v_can_view_task THEN
    RAISE EXCEPTION 'TEST 6 FAILED: newly-assigned outsider should now see the task';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 6 FAILED: outsider should not see the link (can view task but not thread)';
  END IF;
  RAISE NOTICE 'TEST 6 PASSED: user who can view the Task but not the thread cannot see the link';
END $$;
DO $$
DECLARE v_task_id UUID; v_outsider UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1;
  SELECT outsider INTO v_outsider FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  PERFORM unassign_task(v_task_id, v_outsider);
END $$;

-- ─── 7. User who sees thread but not Task cannot see the link ─────
-- A private task, visible only to its creator (helper_staff) and any
-- assignee/watcher, linked to thread1 — case_owner can see thread1
-- (its own creator) but not this private task.
-- Idempotent (checked via a fixed title): re-running this file must
-- not keep creating new private tasks each time.
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R6 Test: private task') THEN
    SELECT task_id, task_number, link_id INTO v_task_id, v_task_number, v_link_id FROM create_internal_collaboration_supporting_task(
      (SELECT thread1 FROM test_ids), 'R6 Test: private task', NULL, NULL, 'normal', 'private', NULL, NULL, NULL
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  ELSE
    SELECT t.id, tl.id INTO v_task_id, v_link_id FROM tasks t
    JOIN task_links tl ON tl.task_id = t.id AND tl.module_key = 'internal_request' AND tl.removed_at IS NULL
    WHERE t.title = 'R6 Test: private task';
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, NULL, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_thread1 UUID; v_can_view_thread BOOLEAN; v_can_view_task BOOLEAN; v_can_view_link BOOLEAN;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at DESC LIMIT 1;
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT case_owner FROM test_ids) || '"}', false);
  v_can_view_thread := can_view_internal_request(v_thread1);
  v_can_view_task := can_view_task(v_task_id);
  v_can_view_link := can_view_task_link(v_task_id, 'internal_request', v_thread1);
  IF NOT v_can_view_thread THEN
    RAISE EXCEPTION 'TEST 7 FAILED: case_owner (thread creator) should see thread1';
  END IF;
  IF v_can_view_task THEN
    RAISE EXCEPTION 'TEST 7 FAILED: case_owner should not see a private task belonging to someone else';
  END IF;
  IF v_can_view_link THEN
    RAISE EXCEPTION 'TEST 7 FAILED: case_owner should not see the link (can view thread but not task)';
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: user who can view the thread but not the Task cannot see the link';
END $$;

-- ─── 8. Duplicate active link rejected ─────────────────────────────
DO $$
DECLARE v_task_id UUID; v_thread1 UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1; -- TEST 1's task
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  BEGIN
    PERFORM link_existing_task_to_internal_collaboration(v_task_id, v_thread1);
    RAISE EXCEPTION 'TEST 8 FAILED: duplicate active link was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 8 FAILED%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'TEST 8 PASSED: duplicate active link rejected';
END $$;

-- ─── 9. Unlink soft-removes without changing Task or thread state ──
DO $$
DECLARE
  v_task_id UUID; v_link_id UUID; v_thread1 UUID;
  v_task_status_before TEXT; v_thread_status_before TEXT;
  v_removed_at TIMESTAMPTZ; v_row_count INT;
BEGIN
  SELECT task_id, link_id INTO v_task_id, v_link_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task_id;
  SELECT status INTO v_thread_status_before FROM internal_requests WHERE id = v_thread1;

  PERFORM unlink_task_from_internal_collaboration(v_link_id, 'test unlink');

  SELECT removed_at, count(*) OVER() INTO v_removed_at, v_row_count FROM task_links WHERE id = v_link_id;
  IF v_removed_at IS NULL THEN
    RAISE EXCEPTION 'TEST 9 FAILED: link row removed_at was not set';
  END IF;
  IF v_row_count <> 1 THEN
    RAISE EXCEPTION 'TEST 9 FAILED: link row was hard-deleted, history not retained';
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 9 FAILED: task status changed on unlink';
  END IF;
  IF (SELECT status FROM internal_requests WHERE id = v_thread1) <> v_thread_status_before THEN
    RAISE EXCEPTION 'TEST 9 FAILED: thread status changed on unlink';
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: unlink soft-removes only, task/thread status untouched, history retained';
END $$;
-- Re-link so later tests still have an active link on this task.
DO $$
DECLARE v_task_id UUID; v_new_link_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  v_new_link_id := link_existing_task_to_internal_collaboration(v_task_id, (SELECT thread1 FROM test_ids));
  UPDATE t1 SET link_id = v_new_link_id WHERE task_id = v_task_id;
END $$;

-- ─── 10. Thread status changes do not change Task status ──────────
-- Direct UPDATE on internal_requests (RLS-permitted for to_section
-- members — same as the existing app's own InternalRequestsAPI.assign/
-- markReceived, there is no RPC wrapper for this, before or after R6).
DO $$
DECLARE v_task2_id UUID; v_thread2 UUID; v_task_status_before TEXT;
BEGIN
  SELECT thread2 INTO v_thread2 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);

  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R6 Test: thread2 lifecycle task') THEN
    SELECT task_id INTO v_task2_id FROM create_internal_collaboration_supporting_task(
      v_thread2, 'R6 Test: thread2 lifecycle task', NULL, NULL, 'normal', 'section', NULL, NULL, NULL
    );
  ELSE
    SELECT id INTO v_task2_id FROM tasks WHERE title = 'R6 Test: thread2 lifecycle task';
  END IF;
  SELECT status INTO v_task_status_before FROM tasks WHERE id = v_task2_id;

  -- CAP-003 Phase 1.8A: internal_requests is no longer directly
  -- writable by authenticated (patch-internal-collaboration-server-
  -- mutation-foundation.sql) -- assign_internal_request() reproduces
  -- this exact effect (assigned_to + status='in_progress') atomically.
  PERFORM assign_internal_request(v_thread2, (SELECT assignee FROM test_ids));

  IF (SELECT status FROM internal_requests WHERE id = v_thread2) <> 'in_progress' THEN
    RAISE EXCEPTION 'TEST 10 FAILED: thread2 status update did not take effect (fixture/RLS problem, not the thing under test)';
  END IF;
  IF (SELECT status FROM tasks WHERE id = v_task2_id) <> v_task_status_before THEN
    RAISE EXCEPTION 'TEST 10 FAILED: task status changed as a side effect of thread status change (% -> %)',
      v_task_status_before, (SELECT status FROM tasks WHERE id = v_task2_id);
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: thread status changes do not change Task status';
END $$;

-- ─── 11. Task status changes do not change thread or parent state ──
DO $$
DECLARE v_task_id UUID; v_thread1 UUID; v_parent_id UUID; v_thread_status_before TEXT; v_parent_status_before TEXT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT thread1, parent_request_id INTO v_thread1, v_parent_id FROM test_ids;
  SELECT status INTO v_thread_status_before FROM internal_requests WHERE id = v_thread1;
  SELECT status INTO v_parent_status_before FROM requests WHERE id = v_parent_id;

  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT assignee FROM test_ids) || '"}', false);
  -- Idempotent: a repeated run finds TEST 1's task already completed
  -- from the first run — valid_task_status_transition() has no
  -- completed->open edge, so re-driving the full draft->...->completed
  -- sequence on an already-completed task would fail on a second run.
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    PERFORM update_task(v_task_id, p_status := 'open');
    PERFORM update_task(v_task_id, p_status := 'in_progress');
    PERFORM complete_task(v_task_id, 'done');
  END IF;

  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 11 FAILED: task should be completed';
  END IF;
  IF (SELECT status FROM internal_requests WHERE id = v_thread1) <> v_thread_status_before THEN
    RAISE EXCEPTION 'TEST 11 FAILED: thread status changed as a side effect of task completion';
  END IF;
  IF (SELECT status FROM requests WHERE id = v_parent_id) <> v_parent_status_before THEN
    RAISE EXCEPTION 'TEST 11 FAILED: parent Request status changed as a side effect of task completion';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: completing the task did not change the thread''s or the parent Request''s status';
END $$;

-- ─── 12. Three-thread isolation ────────────────────────────────────
-- thread1 (open, has tasks from TESTs above), thread2 (open, has its
-- own separate task from TEST 10), thread3 (closed, no tasks) — all
-- three siblings under the SAME parent Request. Each must show only
-- its own tasks; capabilities are evaluated independently (thread3's
-- create/link are blocked by its closed status even though the same
-- actor can fully manage thread1/thread2); unlinking on thread1 must
-- not touch thread2's link.
DO $$
DECLARE
  v_thread1 UUID; v_thread2 UUID; v_thread3 UUID;
  v_thread1_tasks INT; v_thread2_tasks INT; v_thread3_tasks INT;
  v_thread1_task_ids UUID[]; v_thread2_task_ids UUID[];
  v_caps1 RECORD; v_caps2 RECORD; v_caps3 RECORD;
BEGIN
  SELECT thread1, thread2, thread3_closed INTO v_thread1, v_thread2, v_thread3 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);

  SELECT count(*), array_agg(task_id) INTO v_thread1_tasks, v_thread1_task_ids FROM list_internal_collaboration_tasks(v_thread1);
  SELECT count(*), array_agg(task_id) INTO v_thread2_tasks, v_thread2_task_ids FROM list_internal_collaboration_tasks(v_thread2);
  SELECT count(*) INTO v_thread3_tasks FROM list_internal_collaboration_tasks(v_thread3);

  IF v_thread1_tasks < 2 THEN -- TEST 1's task + TEST 7's private task (both linked, TEST7's still active)
    RAISE EXCEPTION 'TEST 12 FAILED: expected at least 2 active tasks on thread1, got %', v_thread1_tasks;
  END IF;
  IF v_thread2_tasks <> 1 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: expected exactly 1 task on thread2, got %', v_thread2_tasks;
  END IF;
  IF v_thread3_tasks <> 0 THEN
    RAISE EXCEPTION 'TEST 12 FAILED: expected 0 tasks on never-linked thread3, got %', v_thread3_tasks;
  END IF;
  IF v_thread1_task_ids && v_thread2_task_ids THEN
    RAISE EXCEPTION 'TEST 12 FAILED: thread1 and thread2 task sets overlap — cross-thread bleed';
  END IF;

  SELECT * INTO v_caps1 FROM get_internal_collaboration_task_capabilities(v_thread1);
  SELECT * INTO v_caps2 FROM get_internal_collaboration_task_capabilities(v_thread2);
  SELECT * INTO v_caps3 FROM get_internal_collaboration_task_capabilities(v_thread3);
  IF NOT (v_caps1.can_create_task AND v_caps1.can_link_existing) THEN
    RAISE EXCEPTION 'TEST 12 FAILED: helper_staff should be able to create/link on open thread1';
  END IF;
  IF NOT (v_caps2.can_create_task AND v_caps2.can_link_existing) THEN
    RAISE EXCEPTION 'TEST 12 FAILED: helper_staff should be able to create/link on open thread2';
  END IF;
  IF v_caps3.can_create_task OR v_caps3.can_link_existing THEN
    RAISE EXCEPTION 'TEST 12 FAILED: create/link must be blocked on closed thread3, got %', v_caps3;
  END IF;
  IF NOT v_caps3.can_view_tasks THEN
    RAISE EXCEPTION 'TEST 12 FAILED: helper_staff (to_section member) should still be able to VIEW thread3''s (empty) task list even though it is closed';
  END IF;

  RAISE NOTICE 'TEST 12 PASSED: three-thread isolation holds — no cross-thread task bleed, capabilities evaluated independently per thread, closed thread blocks create/link but not view';
END $$;

-- Unlink on thread1 must not affect thread2's link (isolation, other direction).
DO $$
DECLARE v_thread1_link UUID; v_thread2_task_id UUID; v_thread2_link UUID; v_removed_before TIMESTAMPTZ; v_removed_after TIMESTAMPTZ;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  SELECT link_id INTO v_thread1_link FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT id INTO v_thread2_task_id FROM tasks WHERE title = 'R6 Test: thread2 lifecycle task';
  SELECT id, removed_at INTO v_thread2_link, v_removed_before FROM task_links
  WHERE task_id = v_thread2_task_id AND module_key = 'internal_request' AND record_id = (SELECT thread2 FROM test_ids) AND removed_at IS NULL;

  PERFORM unlink_task_from_internal_collaboration(v_thread1_link, 'isolation check');

  SELECT removed_at INTO v_removed_after FROM task_links WHERE id = v_thread2_link;
  IF v_removed_after IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 12B FAILED: unlinking a thread1 link removed thread2''s unrelated link';
  END IF;
  RAISE NOTICE 'TEST 12B PASSED: unlink on one thread does not affect a sibling thread''s link';
END $$;
-- Re-link thread1's task so later tests (pagination, audit) still see it.
DO $$
DECLARE v_task_id UUID; v_new_link_id UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  v_new_link_id := link_existing_task_to_internal_collaboration(v_task_id, (SELECT thread1 FROM test_ids));
  UPDATE t1 SET link_id = v_new_link_id WHERE task_id = v_task_id;
END $$;

-- ─── 13. Pagination is deterministic and thread-specific ───────────
DO $$
DECLARE v_thread1 UUID; v_page1_task UUID; v_page1b_task UUID; v_page2_task UUID; v_total1 BIGINT; v_total2 BIGINT;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  SELECT task_id, total_count INTO v_page1_task, v_total1 FROM list_internal_collaboration_tasks(v_thread1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page1b_task, v_total1 FROM list_internal_collaboration_tasks(v_thread1, NULL, FALSE, 1, 0);
  SELECT task_id, total_count INTO v_page2_task, v_total2 FROM list_internal_collaboration_tasks(v_thread1, NULL, FALSE, 1, 1);
  IF v_page1_task IS DISTINCT FROM v_page1b_task THEN
    RAISE EXCEPTION 'TEST 13 FAILED: same offset returned different rows across calls';
  END IF;
  IF v_page1_task = v_page2_task THEN
    RAISE EXCEPTION 'TEST 13 FAILED: offset 0 and offset 1 returned the same row';
  END IF;
  IF v_total1 <> v_total2 OR v_total1 < 2 THEN
    RAISE EXCEPTION 'TEST 13 FAILED: total_count inconsistent across pages (% vs %)', v_total1, v_total2;
  END IF;
  RAISE NOTICE 'TEST 13 PASSED: pagination is deterministic across repeated calls/offsets and stays scoped to one thread';
END $$;

-- ─── 14. Direct writes to task_links denied ─────────────────────────
DO $$
DECLARE
  v_task2_id UUID; v_org_c UUID; v_helper UUID;
  v_rows_before INT; v_rows_after INT; v_insert_failed BOOLEAN := FALSE;
BEGIN
  SELECT org_c, helper_staff INTO v_org_c, v_helper FROM test_ids;
  SELECT id INTO v_task2_id FROM tasks WHERE title = 'R6 Test: assignee-created task';
  SELECT count(*) INTO v_rows_before FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (v_task2_id, 'internal_request', gen_random_uuid(), v_org_c, v_helper);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_insert_failed := TRUE;
  END;
  IF NOT v_insert_failed THEN
    RAISE EXCEPTION 'TEST 14 FAILED: direct INSERT into task_links (module_key=internal_request) succeeded';
  END IF;

  UPDATE task_links SET removed_at = NOW() WHERE task_id = v_task2_id;
  DELETE FROM task_links WHERE task_id = v_task2_id;

  SELECT count(*) INTO v_rows_after FROM task_links WHERE task_id = v_task2_id AND removed_at IS NULL;
  IF v_rows_before <> v_rows_after THEN
    RAISE EXCEPTION 'TEST 14 FAILED: direct UPDATE/DELETE changed task_links rows';
  END IF;
  RAISE NOTICE 'TEST 14 PASSED: direct INSERT/UPDATE/DELETE on task_links all denied or no-op';
END $$;

-- ─── 15. Audit rows created safely ─────────────────────────────────
-- Unlike R5's Meeting milestone, can_view_case_audit_record() already
-- has a record_type='internal_request' branch (pre-existing, long
-- before this milestone) mirroring internal_requests_select — so this
-- check runs as the ordinary `authenticated` test user, no RESET ROLE
-- (superuser bypass) needed.
DO $$
DECLARE v_thread1 UUID; v_linked_count INT; v_unlinked_count INT;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_linked_count FROM audit_logs WHERE action = 'task_linked' AND record_type = 'internal_request' AND record_id = v_thread1;
  SELECT count(*) INTO v_unlinked_count FROM audit_logs WHERE action = 'task_unlinked' AND record_type = 'internal_request' AND record_id = v_thread1;
  IF v_linked_count < 1 THEN
    RAISE EXCEPTION 'TEST 15 FAILED: no task_linked audit row found for thread1 (visible to a to_section member without any RLS bypass)';
  END IF;
  IF v_unlinked_count < 1 THEN
    RAISE EXCEPTION 'TEST 15 FAILED: no task_unlinked audit row found for thread1';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: audit rows exist for both link and unlink actions, visible under record_type=internal_request without any RLS bypass';
END $$;

-- ─── 16. Standalone tasks remain valid ──────────────────────────────
DO $$
DECLARE v_org_c UUID; v_task_id UUID; v_link_count INT;
BEGIN
  SELECT org_c INTO v_org_c FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  v_task_id := create_task(v_org_c, 'R6 Test: standalone task, never linked');
  SELECT count(*) INTO v_link_count FROM task_links WHERE task_id = v_task_id;
  IF v_link_count <> 0 THEN
    RAISE EXCEPTION 'TEST 16 FAILED: a brand-new standalone task should have 0 task_links rows';
  END IF;
  IF NOT can_view_task(v_task_id) THEN
    RAISE EXCEPTION 'TEST 16 FAILED: standalone task should be visible to its own creator';
  END IF;
  -- valid_task_status_transition() requires draft -> open -> in_progress
  -- -> completed (same sequence TEST 11 above already exercises).
  PERFORM update_task(v_task_id, p_status := 'open');
  PERFORM update_task(v_task_id, p_status := 'in_progress');
  PERFORM complete_task(v_task_id, 'standalone, done');
  IF (SELECT status FROM tasks WHERE id = v_task_id) <> 'completed' THEN
    RAISE EXCEPTION 'TEST 16 FAILED: standalone task lifecycle (complete) should work unaffected by this milestone';
  END IF;
  RAISE NOTICE 'TEST 16 PASSED: standalone tasks (no module link at all) remain fully valid and independent';
END $$;

-- ─── 17/18. Request/Meeting integration still work ─────────────────
-- Deliberately not reproduced here — see the file header. Verified by
-- re-running supabase/test-request-task-integration.sql and supabase/
-- test-meeting-task-integration.sql end to end against this same,
-- R6-patched database; both passed identically to their pre-R6 runs.

-- ─── 19. Parent Request-hosted collaboration + navigation metadata ──
DO $$
DECLARE v_task_id UUID; v_parent_type TEXT; v_parent_id UUID; v_expected_parent UUID;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  SELECT parent_request_id INTO v_expected_parent FROM test_ids;
  -- helper_staff, not case_owner: TEST 1's task has visibility='section'
  -- scoped to section_helper, so the viewer needs BOTH task visibility
  -- (helper_staff qualifies via section match; case_owner does not) and
  -- parent-Request visibility (helper_staff gets this via
  -- looped_in_via_internal_collab() — being to_section on a thread
  -- anchored to that Request — same mechanism the real UI already
  -- relies on to show "Case" info to a looped-in section).
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  SELECT parent_type, parent_id INTO v_parent_type, v_parent_id FROM list_task_internal_collaboration_links(v_task_id) LIMIT 1;
  IF v_parent_type IS DISTINCT FROM 'request' OR v_parent_id IS DISTINCT FROM v_expected_parent THEN
    RAISE EXCEPTION 'TEST 19 FAILED: expected parent_type=request, parent_id=%, got type=%, id=%', v_expected_parent, v_parent_type, v_parent_id;
  END IF;
  RAISE NOTICE 'TEST 19 PASSED: Request-hosted thread resolves safe parent navigation metadata (parent_type=request) for an authorized viewer';
END $$;

-- ─── 20. Parent Entry-hosted collaboration works ────────────────────
-- Idempotent: only create+link once (checked via a fixed title),
-- since this milestone's create RPC has no natural "already exists"
-- constraint of its own to lean on the way TEST 8's duplicate-link
-- check does — re-running this file must not keep growing thread4's
-- task count.
DO $$
DECLARE v_task_id UUID; v_link_id UUID; v_task_number TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);
  IF NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'R6 Test: entry-hosted supporting task') THEN
    SELECT task_id, link_id, task_number INTO v_task_id, v_link_id, v_task_number FROM create_internal_collaboration_supporting_task(
      (SELECT thread4_entry FROM test_ids), 'R6 Test: entry-hosted supporting task', NULL, NULL, 'normal', 'section', NULL, NULL, NULL
    );
    INSERT INTO t1 (task_id, task_number, link_id) VALUES (v_task_id, v_task_number, v_link_id);
  END IF;
END $$;
DO $$
DECLARE v_task_id UUID; v_thread4 UUID; v_expected_parent UUID; v_parent_type TEXT; v_parent_id UUID; v_list_count INT;
BEGIN
  SELECT id INTO v_task_id FROM tasks WHERE title = 'R6 Test: entry-hosted supporting task';
  SELECT thread4_entry, parent_entry_id INTO v_thread4, v_expected_parent FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT helper_staff FROM test_ids) || '"}', false);

  SELECT count(*) INTO v_list_count FROM list_internal_collaboration_tasks(v_thread4);
  IF v_list_count <> 1 THEN
    RAISE EXCEPTION 'TEST 20 FAILED: expected exactly 1 task on the entry-hosted thread, got %', v_list_count;
  END IF;

  SELECT parent_type, parent_id INTO v_parent_type, v_parent_id FROM list_task_internal_collaboration_links(v_task_id) LIMIT 1;
  IF v_parent_type IS DISTINCT FROM 'external_correspondence' OR v_parent_id IS DISTINCT FROM v_expected_parent THEN
    RAISE EXCEPTION 'TEST 20 FAILED: expected parent_type=external_correspondence, parent_id=%, got type=%, id=%', v_expected_parent, v_parent_type, v_parent_id;
  END IF;
  RAISE NOTICE 'TEST 20 PASSED: Entry-hosted collaboration works — task creation, listing, and parent navigation metadata all correct';
END $$;

-- ─── 21. Error behavior fails closed without record-existence leakage ──
DO $$
DECLARE v_caps_real RECORD; v_caps_fake RECORD; v_thread1 UUID;
BEGIN
  SELECT thread1 INTO v_thread1 FROM test_ids;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT outsider FROM test_ids) || '"}', false);
  SELECT * INTO v_caps_real FROM get_internal_collaboration_task_capabilities(v_thread1); -- exists, outsider can't see it
  SELECT * INTO v_caps_fake FROM get_internal_collaboration_task_capabilities(gen_random_uuid()); -- does not exist at all
  IF v_caps_real IS DISTINCT FROM v_caps_fake THEN
    RAISE EXCEPTION 'TEST 21 FAILED: capabilities differ between a real-but-invisible thread and a nonexistent one — this leaks existence (real=%, fake=%)', v_caps_real, v_caps_fake;
  END IF;
  IF v_caps_real.can_view_tasks OR v_caps_real.can_create_task OR v_caps_real.can_link_existing OR v_caps_real.can_unlink THEN
    RAISE EXCEPTION 'TEST 21 FAILED: capabilities should be uniformly all-false in both cases, got %', v_caps_real;
  END IF;

  -- Unauthenticated caller (no JWT at all) also fails closed.
  PERFORM set_config('request.jwt.claims', '', false);
  SELECT * INTO v_caps_fake FROM get_internal_collaboration_task_capabilities(v_thread1);
  IF v_caps_fake.can_view_tasks OR v_caps_fake.can_create_task OR v_caps_fake.can_link_existing OR v_caps_fake.can_unlink THEN
    RAISE EXCEPTION 'TEST 21 FAILED: unauthenticated caller should get all-false capabilities, got %', v_caps_fake;
  END IF;
  RAISE NOTICE 'TEST 21 PASSED: capabilities RPC fails closed uniformly, with no distinguishable existence leakage for a hidden vs. nonexistent thread';
END $$;

-- ─── list_task_internal_collaboration_links parent-visibility guard ──
-- A viewer who can see the TASK but not its parent Request/Entry (or
-- the thread at all) must get NULL parent_type/parent_id, not a
-- silently-wrong one. otherorg cannot see thread1's task at all here
-- (cross-org), so list_task_internal_collaboration_links returns 0
-- rows for them — the strongest form of "don't expose it".
DO $$
DECLARE v_task_id UUID; v_row_count INT;
BEGIN
  SELECT task_id INTO v_task_id FROM t1 ORDER BY inserted_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"' || (SELECT otherorg FROM test_ids) || '"}', false);
  SELECT count(*) INTO v_row_count FROM list_task_internal_collaboration_links(v_task_id);
  IF v_row_count <> 0 THEN
    RAISE EXCEPTION 'TEST parent-visibility-guard FAILED: cross-org user should see 0 linked threads for a task they cannot view, saw %', v_row_count;
  END IF;
  RAISE NOTICE 'TEST parent-visibility-guard PASSED: a viewer with no visibility into the task/thread gets 0 rows, never a partially-populated one';
END $$;

RESET ROLE;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS test_ids;

DO $$ BEGIN RAISE NOTICE 'ALL INTERNAL COLLABORATION TASK INTEGRATION TESTS PASSED'; END $$;
