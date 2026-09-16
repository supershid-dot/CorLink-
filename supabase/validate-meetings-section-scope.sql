-- ─── Behavioral validation: meetings section-scoped access control ──
-- Run manually against a project AFTER patch-meetings-section-scope.sql
-- has been applied there. Creates disposable fixture rows (fixed,
-- distinctively-prefixed test UUIDs) inside ONE transaction and ROLLS
-- BACK at the very end — nothing here persists, safe to run against a
-- live/populated project. Each scenario RAISEs an exception with a
-- clear message on failure; a clean run (no exception, transaction
-- rolled back) means every scenario passed.
--
-- Fixture shape: one org, one command, one department under it, two
-- sections under that department (sec-a, sec-b) plus one unrelated
-- section (sec-c) in a different department. Actors:
--   staff-a      — role='staff',      scope='section',    sec-a
--   staff-b      — role='staff',      scope='section',    sec-b  AND
--                  role='staff',      scope='section',    sec-c
--                  (multi-section membership)
--   dept-head    — role='supervisor', scope='department', the dept
--   cmd-head     — role='supervisor', scope='command',    the command
--   outsider     — no assignment anywhere
--   org-admin    — role='mcs_admin',  scope='section', sec-c (any
--                  scope — is_admin()/has_role() ignore scope_id, this
--                  intentionally exercises that it still works)
-- A meeting is created (as staff-a, so staff-a is creator) tagged to
-- sec-a.

BEGIN;

INSERT INTO organizations (id, name, type, code) VALUES
  ('7a000000-0000-0000-0000-000000000001', 'MSV Test Org', 'mcs', 'MSVT');
INSERT INTO commands (id, org_id, name) VALUES
  ('7a000000-0001-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001', 'Test Command');
INSERT INTO departments (id, command_id, name) VALUES
  ('7a000000-0002-0000-0000-000000000001', '7a000000-0001-0000-0000-000000000001', 'Test Department'),
  ('7a000000-0002-0000-0000-000000000002', '7a000000-0001-0000-0000-000000000001', 'Other Department');
INSERT INTO sections (id, org_id, department_id, name, code) VALUES
  ('7a000000-0003-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001', '7a000000-0002-0000-0000-000000000001', 'Section A', 'SECA'),
  ('7a000000-0003-0000-0000-000000000002', '7a000000-0000-0000-0000-000000000001', '7a000000-0002-0000-0000-000000000001', 'Section B', 'SECB'),
  ('7a000000-0003-0000-0000-000000000003', '7a000000-0000-0000-0000-000000000001', '7a000000-0002-0000-0000-000000000002', 'Section C', 'SECC');

INSERT INTO auth.users (id, email) VALUES
  ('7a000000-0004-0000-0000-000000000001', 'msv-staffa@t.local'),
  ('7a000000-0004-0000-0000-000000000002', 'msv-staffb@t.local'),
  ('7a000000-0004-0000-0000-000000000003', 'msv-depthead@t.local'),
  ('7a000000-0004-0000-0000-000000000004', 'msv-cmdhead@t.local'),
  ('7a000000-0004-0000-0000-000000000005', 'msv-outsider@t.local'),
  ('7a000000-0004-0000-0000-000000000006', 'msv-orgadmin@t.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
  ('7a000000-0004-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001', 'MSV-1', 'Staff A', 'msv-staffa@t.local', TRUE),
  ('7a000000-0004-0000-0000-000000000002', '7a000000-0000-0000-0000-000000000001', 'MSV-2', 'Staff B', 'msv-staffb@t.local', TRUE),
  ('7a000000-0004-0000-0000-000000000003', '7a000000-0000-0000-0000-000000000001', 'MSV-3', 'Dept Head', 'msv-depthead@t.local', TRUE),
  ('7a000000-0004-0000-0000-000000000004', '7a000000-0000-0000-0000-000000000001', 'MSV-4', 'Cmd Head', 'msv-cmdhead@t.local', TRUE),
  ('7a000000-0004-0000-0000-000000000005', '7a000000-0000-0000-0000-000000000001', 'MSV-5', 'Outsider', 'msv-outsider@t.local', TRUE),
  ('7a000000-0004-0000-0000-000000000006', '7a000000-0000-0000-0000-000000000001', 'MSV-6', 'Org Admin', 'msv-orgadmin@t.local', TRUE);

INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('7a000000-0004-0000-0000-000000000001', 'section',    '7a000000-0003-0000-0000-000000000001', 'staff',      TRUE, TRUE),
  ('7a000000-0004-0000-0000-000000000002', 'section',    '7a000000-0003-0000-0000-000000000002', 'staff',      TRUE, TRUE),
  ('7a000000-0004-0000-0000-000000000002', 'section',    '7a000000-0003-0000-0000-000000000003', 'staff',      FALSE, TRUE),
  ('7a000000-0004-0000-0000-000000000003', 'department', '7a000000-0002-0000-0000-000000000001', 'supervisor', TRUE, TRUE),
  ('7a000000-0004-0000-0000-000000000004', 'command',    '7a000000-0001-0000-0000-000000000001', 'supervisor', TRUE, TRUE),
  ('7a000000-0004-0000-0000-000000000006', 'section',    '7a000000-0003-0000-0000-000000000003', 'mcs_admin',  TRUE, TRUE);

-- meetings_module_active_for() gates every meetings RPC on both a
-- platform-wide platform_modules.is_active flag (already true for the
-- real, already-shipped 'meetings' module — untouched here) and a
-- per-org organization_modules.is_enabled row, which this fixture org
-- doesn't have yet.
INSERT INTO organization_modules (organization_id, module_id, is_enabled)
SELECT '7a000000-0000-0000-0000-000000000001', pm.id, TRUE
FROM platform_modules pm WHERE pm.module_key = 'meetings';

SET ROLE authenticated;

DO $$
DECLARE
  v_meeting_id UUID;
BEGIN
  -- Staff A creates a meeting tagged to Section A.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000001"}', true);
  v_meeting_id := create_meeting(
    p_title := 'MSV Validate Meeting', p_start_at := now() + interval '1 day',
    p_end_at := now() + interval '1 day 1 hour', p_section_id := '7a000000-0003-0000-0000-000000000001'
  );

  IF NOT can_manage_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: creator (staff-a) should be able to manage their own meeting';
  END IF;

  -- Staff B: not in Section A (only B and C) — must NOT see/manage it.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000002"}', true);
  IF can_manage_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: staff-b (sections B/C only) must NOT manage a Section-A meeting';
  END IF;
  IF can_view_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: staff-b must NOT even view a participants-only Section-A meeting they are not part of';
  END IF;

  -- Department head (scoped to the department containing Section A) — should manage it.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000003"}', true);
  IF NOT can_manage_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: department head over Section A''s department must be able to manage it';
  END IF;
  IF NOT can_view_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: department head must be able to view it too';
  END IF;

  -- Command head (scoped to the command containing that department) — should also manage it.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000004"}', true);
  IF NOT can_manage_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: command head over the whole command must be able to manage a Section-A meeting';
  END IF;

  -- Outsider — no assignment anywhere — must not manage or view.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000005"}', true);
  IF can_manage_meeting(v_meeting_id) OR can_view_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: an outsider with no assignment must have zero access';
  END IF;

  -- Org admin (mcs_admin role, scoped to an UNRELATED section C) — is_admin()
  -- ignores scope_id by design (has_role() checks role only), so this
  -- should still manage/view every meeting in the org.
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000006"}', true);
  IF NOT can_manage_meeting(v_meeting_id) THEN
    RAISE EXCEPTION 'FAIL: an org admin (mcs_admin) must retain full org-wide manage access regardless of scope';
  END IF;

  -- Lock the meeting (as staff-a, the creator) and re-check: the
  -- department head must now be BLOCKED from update_meeting (lock
  -- override is creator/admin/super-admin only, unchanged by this
  -- patch) even though can_manage_meeting() itself still returns true
  -- for them (can_manage_meeting and the lock-override gate are two
  -- separate checks, exactly as they were before this patch).
  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000001"}', true);
  PERFORM lock_meeting(v_meeting_id);

  PERFORM set_config('request.jwt.claims', '{"sub":"7a000000-0004-0000-0000-000000000003"}', true);
  BEGIN
    PERFORM update_meeting(v_meeting_id, p_title := 'Should be blocked by lock');
    RAISE EXCEPTION 'FAIL: department head must NOT be able to update a LOCKED Section-A meeting';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%locked%' THEN
      RAISE EXCEPTION 'FAIL: expected a lock-related rejection, got: %', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'PASS: all meetings section-scope access-control scenarios behaved as designed';
END $$;

RESET ROLE;

ROLLBACK;
