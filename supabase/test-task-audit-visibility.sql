-- ============================================================
-- CorLink — Behavioral/RLS test: Task Audit Visibility Correction (T2C.1)
-- Companion to supabase/patch-task-audit-visibility.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (fixed
-- 'eeeeeeee-...'-prefixed UUIDs) and exercises real audit_logs SELECT
-- behavior under a real, non-superuser `authenticated` role via
-- request.jwt.claims impersonation (SET ROLE authenticated +
-- set_config('request.jwt.claims', ...) — matching supabase/test-
-- entry-task-integration.sql's own established convention exactly,
-- not superuser-only assertions). Run this ONLY against a disposable/
-- local test database with the full migration chain through
-- patch-task-audit-visibility.sql already applied — NEVER against
-- staging or production. Idempotent (ON CONFLICT DO NOTHING
-- fixtures); not side-effect-free (creates real rows, including one
-- real add_task_comment() call in TEST 8).
--
-- inserted_at ordering is not needed here (every assertion below
-- checks presence/absence of specific known rows, not "most recent"),
-- so the R6-discovered random-UUID-ordering pitfall doesn't apply to
-- this file.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures ─────────────────────────────────────
-- Org T: creator, an active assignee, a watcher, a section-scoped
-- supervisor covering the task's own section, and unrelated same-org
-- staff in a DIFFERENT section (the task's visibility is 'section',
-- not 'organization', specifically so this negative case is
-- meaningful). Org X: a cross-org user, structurally unable to see
-- anything in Org T regardless of this patch (can_view_task()'s WHERE
-- clause requires organization_id = get_my_org_id() outside the
-- is_super_admin() bypass).
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('eeeeeeee-0000-0000-0000-000000000001', 'T2C1 Test Org T', 'mcs', 'T2C1T'),
    ('eeeeeeee-0000-0000-0000-000000000002', 'T2C1 Test Org X', 'authority', 'T2C1X')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO commands (id, name, org_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000010', 'T2C1 Command T', 'eeeeeeee-0000-0000-0000-000000000001'),
    ('eeeeeeee-0000-0000-0000-000000000011', 'T2C1 Command X', 'eeeeeeee-0000-0000-0000-000000000002')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO departments (id, name, command_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000020', 'T2C1 Department T', 'eeeeeeee-0000-0000-0000-000000000010'),
    ('eeeeeeee-0000-0000-0000-000000000021', 'T2C1 Department X', 'eeeeeeee-0000-0000-0000-000000000011')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000030', 'T2C1 Task Section',     'T2CTS', 'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000020'),
    ('eeeeeeee-0000-0000-0000-000000000031', 'T2C1 Unrelated Section','T2CUS', 'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000020'),
    ('eeeeeeee-0000-0000-0000-000000000040', 'T2C1 Org X Section',    'T2CXS', 'eeeeeeee-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000021')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('eeeeeeee-0001-0000-0000-000000000001', 't2c1-creator@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000002', 't2c1-assignee@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000003', 't2c1-watcher@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000004', 't2c1-supervisor@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000005', 't2c1-unrelated@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000006', 't2c1-otherorg@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('eeeeeeee-0001-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'T2C1-001', 'T2C1 Creator',    't2c1-creator@test.local',    TRUE),
    ('eeeeeeee-0001-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001', 'T2C1-002', 'T2C1 Assignee',   't2c1-assignee@test.local',   TRUE),
    ('eeeeeeee-0001-0000-0000-000000000003', 'eeeeeeee-0000-0000-0000-000000000001', 'T2C1-003', 'T2C1 Watcher',    't2c1-watcher@test.local',    TRUE),
    ('eeeeeeee-0001-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000001', 'T2C1-004', 'T2C1 Supervisor', 't2c1-supervisor@test.local', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000005', 'eeeeeeee-0000-0000-0000-000000000001', 'T2C1-005', 'T2C1 Unrelated',  't2c1-unrelated@test.local',  TRUE),
    ('eeeeeeee-0001-0000-0000-000000000006', 'eeeeeeee-0000-0000-0000-000000000002', 'T2C1-006', 'T2C1 OtherOrg',   't2c1-otherorg@test.local',   TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- Supervisor scoped to the TASK's own section specifically (not
  -- org-wide) — exercises can_view_task()'s actual predicate
  -- (is_supervisor_or_above() AND owning_section_id IN my_section_ids()),
  -- not a coarser org-admin bypass.
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary) VALUES
    ('eeeeeeee-0001-0000-0000-000000000001', 'section', 'eeeeeeee-0000-0000-0000-000000000030', 'staff', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000002', 'section', 'eeeeeeee-0000-0000-0000-000000000031', 'staff', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000003', 'section', 'eeeeeeee-0000-0000-0000-000000000031', 'staff', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000004', 'section', 'eeeeeeee-0000-0000-0000-000000000030', 'supervisor', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000005', 'section', 'eeeeeeee-0000-0000-0000-000000000031', 'staff', TRUE),
    ('eeeeeeee-0001-0000-0000-000000000006', 'section', 'eeeeeeee-0000-0000-0000-000000000040', 'staff', TRUE)
  ON CONFLICT (user_id, scope_type, scope_id, role) DO NOTHING;

  -- The task itself: created by Creator, owned by the Task Section,
  -- visibility='section' (deliberately NOT 'organization' — TEST 5
  -- needs a same-org viewer who genuinely cannot see it).
  INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
  VALUES (
    'eeeeeeee-0002-0000-0000-000000000001', 'TSK-T2C1-000001', 'T2C1 audit visibility test task',
    'open', 'normal', 'eeeeeeee-0001-0000-0000-000000000001',
    'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000030', 'section'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active) VALUES
    ('eeeeeeee-0002-0000-0000-000000000001', 'eeeeeeee-0001-0000-0000-000000000002', 'eeeeeeee-0001-0000-0000-000000000001', NOW(), TRUE)
  ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING;

  INSERT INTO task_watchers (task_id, user_id) VALUES
    ('eeeeeeee-0002-0000-0000-000000000001', 'eeeeeeee-0001-0000-0000-000000000003')
  ON CONFLICT (task_id, user_id) DO NOTHING;

  -- A real task audit row (created), inserted as postgres (bypasses
  -- RLS at write time — audit_insert's own WITH CHECK is exercised
  -- elsewhere, not the point of this file) so every SELECT test below
  -- has a genuine row to find or correctly fail to find.
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  SELECT 'eeeeeeee-0001-0000-0000-000000000001', 'created', 'task', 'eeeeeeee-0002-0000-0000-000000000001', 'T2C1 fixture: task created'
  WHERE NOT EXISTS (
    SELECT 1 FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001' AND action = 'created'
  );

  -- ── Regression fixtures (TESTS 9-11): one request, one
  -- internal_request, one prisoner_letter, each with a real audit row,
  -- reusing Org T/Org X and a couple of extra sections so the request's
  -- existing dual-org shape is genuine, not faked.
  INSERT INTO sections (id, name, code, org_id, department_id) VALUES
    ('eeeeeeee-0000-0000-0000-000000000032', 'T2C1 From Section', 'T2CFR', 'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000020')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, subject, body, status, reference_number)
  VALUES (
    'eeeeeeee-0003-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    'eeeeeeee-0000-0000-0000-000000000032', 'eeeeeeee-0000-0000-0000-000000000040',
    'eeeeeeee-0001-0000-0000-000000000001', 'T2C1 regression request', 'body', 'sent', 'T2C1-REQ-000001'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  SELECT 'eeeeeeee-0001-0000-0000-000000000001', 'created', 'request', 'eeeeeeee-0003-0000-0000-000000000001', 'T2C1 fixture: request created'
  WHERE NOT EXISTS (
    SELECT 1 FROM audit_logs WHERE record_type = 'request' AND record_id = 'eeeeeeee-0003-0000-0000-000000000001' AND action = 'created'
  );

  INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
  VALUES (
    'eeeeeeee-0004-0000-0000-000000000001', 'eeeeeeee-0003-0000-0000-000000000001',
    'eeeeeeee-0000-0000-0000-000000000030', 'eeeeeeee-0000-0000-0000-000000000031',
    'eeeeeeee-0001-0000-0000-000000000001', 'T2C1 regression internal request', 'body', 'sent'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  SELECT 'eeeeeeee-0001-0000-0000-000000000001', 'created', 'internal_request', 'eeeeeeee-0004-0000-0000-000000000001', 'T2C1 fixture: internal request created'
  WHERE NOT EXISTS (
    SELECT 1 FROM audit_logs WHERE record_type = 'internal_request' AND record_id = 'eeeeeeee-0004-0000-0000-000000000001' AND action = 'created'
  );

  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status, reference_number)
  VALUES (
    'eeeeeeee-0005-0000-0000-000000000001', 'T2C1-P001', 'T2C1 Test Prisoner',
    'eeeeeeee-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    'body', 'eeeeeeee-0001-0000-0000-000000000001', 'submitted', 'T2C1-PL-000001'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  SELECT 'eeeeeeee-0001-0000-0000-000000000001', 'created', 'prisoner_letter', 'eeeeeeee-0005-0000-0000-000000000001', 'T2C1 fixture: prisoner letter created'
  WHERE NOT EXISTS (
    SELECT 1 FROM audit_logs WHERE record_type = 'prisoner_letter' AND record_id = 'eeeeeeee-0005-0000-0000-000000000001' AND action = 'created'
  );
END $$;

-- ─── Impersonated tests (real authenticated role, real RLS) ────────
SET ROLE authenticated;

-- TEST 1: Task creator can see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 1 FAILED: creator cannot see task audit events'; END IF;
  RAISE NOTICE 'TEST 1 PASSED: creator sees % task audit row(s)', v_count;
END $$;

-- TEST 2: Active assignee can see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000002"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 2 FAILED: active assignee cannot see task audit events'; END IF;
  RAISE NOTICE 'TEST 2 PASSED: assignee sees % task audit row(s)', v_count;
END $$;

-- TEST 3: Active watcher can see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000003"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 3 FAILED: active watcher cannot see task audit events'; END IF;
  RAISE NOTICE 'TEST 3 PASSED: watcher sees % task audit row(s)', v_count;
END $$;

-- TEST 4: Authorized supervisor (scoped to the task's own section) can
-- see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000004"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 4 FAILED: authorized supervisor cannot see task audit events'; END IF;
  RAISE NOTICE 'TEST 4 PASSED: supervisor sees % task audit row(s)', v_count;
END $$;

-- TEST 5: Unrelated same-org staff (different section, not
-- creator/assignee/watcher, task visibility='section' not
-- 'organization') CANNOT see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000005"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'TEST 5 FAILED: unrelated same-org staff incorrectly sees % task audit row(s)', v_count; END IF;
  RAISE NOTICE 'TEST 5 PASSED: unrelated same-org staff correctly sees 0 rows';
END $$;

-- TEST 6: Cross-org user cannot see Task audit events.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000006"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'TEST 6 FAILED: cross-org user incorrectly sees % task audit row(s)', v_count; END IF;
  RAISE NOTICE 'TEST 6 PASSED: cross-org user correctly sees 0 rows';
END $$;

-- TEST 7: A user who cannot view the Task cannot infer audit-event
-- existence or count either — same neutral "0, not an error, not a
-- differently-shaped response" as TEST 5/6, checked explicitly via a
-- second, independent read shape (a plain SELECT *, not just COUNT)
-- to confirm nothing leaks through row shape/columns/error text.
DO $$
DECLARE v_rows RECORD;
  v_found BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000005"}', false);
  FOR v_rows IN SELECT * FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001' LOOP
    v_found := TRUE;
  END LOOP;
  IF v_found THEN RAISE EXCEPTION 'TEST 7 FAILED: unauthorized user could enumerate a task audit row'; END IF;
  RAISE NOTICE 'TEST 7 PASSED: unauthorized user''s SELECT * returns zero rows, no error, no leakage';
END $$;

-- TEST 8: Comment creation produces one task_comments row (with body)
-- and one audit row; frontend de-duplication (only the comment row
-- renders, not a second "commented" timeline event) is independently
-- verified by the T2C headless harness (docs/42) — this test confirms
-- the DATA side: both rows genuinely exist after a real
-- add_task_comment() call by an authorized viewer.
DO $$
DECLARE v_comment_id UUID;
  v_comment_count INT;
  v_audit_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
  IF NOT EXISTS (SELECT 1 FROM task_comments WHERE task_id = 'eeeeeeee-0002-0000-0000-000000000001' AND body = 'T2C1 test comment') THEN
    SELECT add_task_comment('eeeeeeee-0002-0000-0000-000000000001', 'T2C1 test comment') INTO v_comment_id;
  END IF;
  SELECT count(*) INTO v_comment_count FROM task_comments WHERE task_id = 'eeeeeeee-0002-0000-0000-000000000001' AND body = 'T2C1 test comment';
  SELECT count(*) INTO v_audit_count FROM audit_logs WHERE record_type = 'task' AND record_id = 'eeeeeeee-0002-0000-0000-000000000001' AND action = 'commented';
  IF v_comment_count <> 1 THEN RAISE EXCEPTION 'TEST 8 FAILED: expected exactly 1 task_comments row, found %', v_comment_count; END IF;
  IF v_audit_count <> 1 THEN RAISE EXCEPTION 'TEST 8 FAILED: expected exactly 1 commented audit row, found %', v_audit_count; END IF;
  RAISE NOTICE 'TEST 8 PASSED: add_task_comment() produced exactly 1 task_comments row + 1 commented audit row (frontend de-dup independently verified by the T2C harness)';
END $$;

-- TEST 9: Existing Request audit visibility unchanged — the request's
-- own creator (a role this patch never touches) still sees its audit
-- trail exactly as before.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'request' AND record_id = 'eeeeeeee-0003-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 9 FAILED: request creator lost visibility into request audit trail — REGRESSION'; END IF;
  RAISE NOTICE 'TEST 9 PASSED: request audit visibility unchanged (% row(s))', v_count;
END $$;

-- TEST 10: Existing Internal Collaboration audit visibility unchanged.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'internal_request' AND record_id = 'eeeeeeee-0004-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'TEST 10 FAILED: internal request creator lost visibility into its audit trail — REGRESSION'; END IF;
  RAISE NOTICE 'TEST 10 PASSED: internal collaboration audit visibility unchanged (% row(s))', v_count;
END $$;

-- TEST 11: Prisoner Letter confidentiality remains unchanged — this
-- patch deliberately does NOT add a prisoner_letter branch (per this
-- milestone's explicit scope), so an ordinary same-org submitter
-- (not an admin) must STILL see 0 rows, exactly as before. A non-zero
-- result here would mean this patch accidentally widened something it
-- was explicitly told not to touch.
DO $$
DECLARE v_count INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
  SELECT count(*) INTO v_count FROM audit_logs WHERE record_type = 'prisoner_letter' AND record_id = 'eeeeeeee-0005-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'TEST 11 FAILED: prisoner_letter audit visibility unexpectedly widened (% rows) — out of this patch''s explicit scope', v_count; END IF;
  RAISE NOTICE 'TEST 11 PASSED: prisoner_letter confidentiality unchanged — still admin-only, as explicitly scoped';
END $$;

RESET ROLE;

DO $$
BEGIN
  RAISE NOTICE 'Task Audit Visibility behavioral test suite: ALL 11 SCENARIOS PASSED';
END $$;
