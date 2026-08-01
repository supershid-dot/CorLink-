-- ============================================================
-- CorLink — Behavioral/RLS test: Task Attachments (T3D)
-- Companion to supabase/patch-task-attachments.sql
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (fixed
-- 'ffffffff-...'-prefixed UUIDs) and exercises real attachments
-- SELECT/INSERT/DELETE RLS behavior under a real, non-superuser
-- `authenticated` role via request.jwt.claims impersonation — same
-- SET ROLE authenticated + set_config('request.jwt.claims', ..., false)
-- convention supabase/test-task-audit-visibility.sql already
-- established (session-level, not per-statement SET LOCAL — a plain
-- autocommitted script has no enclosing transaction for SET LOCAL to
-- live inside, so it would silently revert before the very next
-- statement). Run this ONLY against a disposable/local test database
-- with the full migration chain through patch-task-attachments.sql
-- already applied — NEVER against staging or production. Idempotent
-- (ON CONFLICT DO NOTHING fixtures); not side-effect-free (creates/
-- deletes real attachments rows).
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures (as superuser, before impersonating) ─
-- Org T: creator, an active assignee, an unrelated same-org staffer
-- (no section membership, no supervised section — must be denied),
-- and a supervisor of the task's own section. Task visibility is
-- 'private' specifically so the negative (unrelated-staffer) case is
-- meaningful — a broader 'organization'/'section' visibility would
-- make everyone able to see it, defeating the point of that check.
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('ffffffff-0000-0000-0000-000000000001', 'T3D Test Org', 'authority', 'T3DORG')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO divisions (id, name, org_id) VALUES
    ('ffffffff-0000-0000-0000-000000000010', 'T3D Division', 'ffffffff-0000-0000-0000-000000000001')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, division_id) VALUES
    ('ffffffff-0000-0000-0000-000000000020', 'T3D Task Section', 'T3DTS', 'ffffffff-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000010')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('ffffffff-0001-0000-0000-000000000001', 't3d-creator@test.local'),
    ('ffffffff-0001-0000-0000-000000000002', 't3d-assignee@test.local'),
    ('ffffffff-0001-0000-0000-000000000003', 't3d-stranger@test.local'),
    ('ffffffff-0001-0000-0000-000000000004', 't3d-supervisor@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('ffffffff-0001-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000001', 'T3D-001', 'T3D Creator',    't3d-creator@test.local',    TRUE),
    ('ffffffff-0001-0000-0000-000000000002', 'ffffffff-0000-0000-0000-000000000001', 'T3D-002', 'T3D Assignee',   't3d-assignee@test.local',   TRUE),
    ('ffffffff-0001-0000-0000-000000000003', 'ffffffff-0000-0000-0000-000000000001', 'T3D-003', 'T3D Stranger',   't3d-stranger@test.local',   TRUE),
    ('ffffffff-0001-0000-0000-000000000004', 'ffffffff-0000-0000-0000-000000000001', 'T3D-004', 'T3D Supervisor', 't3d-supervisor@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary) VALUES
    ('ffffffff-0001-0000-0000-000000000004', 'section', 'ffffffff-0000-0000-0000-000000000020', 'supervisor', TRUE)
  ON CONFLICT (user_id, scope_type, scope_id, role) DO NOTHING;

  INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility) VALUES
    ('ffffffff-0002-0000-0000-000000000001', 'TSK-T3D-TEST', 'T3D test task', 'open', 'normal',
     'ffffffff-0001-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000020', 'private')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active) VALUES
    ('ffffffff-0002-0000-0000-000000000001', 'ffffffff-0001-0000-0000-000000000002', 'ffffffff-0001-0000-0000-000000000001', TRUE)
  ON CONFLICT DO NOTHING;

  -- Idempotent re-run safety: an earlier run's TEST 9 deliberately
  -- flips this back off before finishing, but restore it here too in
  -- case a prior run was interrupted mid-test.
  UPDATE task_assignments SET is_active = TRUE
    WHERE task_id = 'ffffffff-0002-0000-0000-000000000001' AND user_id = 'ffffffff-0001-0000-0000-000000000002';

  INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by) VALUES
    ('ffffffff-0003-0000-0000-000000000001', 'task', 'ffffffff-0002-0000-0000-000000000001',
     'notes.pdf', 'task/ffffffff-0002-0000-0000-000000000001/1-notes.pdf', 'application/pdf', 1024,
     'ffffffff-0001-0000-0000-000000000001')
  ON CONFLICT (id) DO NOTHING;
END $$;

-- Session-level impersonation from here on — same convention as
-- supabase/test-task-audit-visibility.sql: one SET ROLE for the rest
-- of the session, set_config(..., false) (not is_local) to actually
-- switch "who" before each check, one RESET ROLE at the very end.
SET ROLE authenticated;

-- ─── TEST 1: creator can SELECT the task's attachment ───────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000001"}', false);
SELECT count(*) = 1 AS test_1_creator_can_select
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';

-- ─── TEST 2: active assignee can SELECT it too ──────────────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000002"}', false);
SELECT count(*) = 1 AS test_2_assignee_can_select
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';

-- ─── TEST 3: unrelated same-org stranger CANNOT SELECT it
--     (private visibility, not creator/assignee/supervisor-of-section) ──
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000003"}', false);
SELECT count(*) = 0 AS test_3_stranger_cannot_select
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';

-- ─── TEST 4: supervisor of the owning section CAN SELECT it ─────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000004"}', false);
SELECT count(*) = 1 AS test_4_supervisor_can_select
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';

-- ─── TEST 5: unrelated stranger CANNOT INSERT an attachment ─────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000003"}', false);
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('task', 'ffffffff-0002-0000-0000-000000000001', 'x.pdf', 'task/x/1-x.pdf', 'application/pdf', 100, 'ffffffff-0001-0000-0000-000000000003');
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_rejected := TRUE;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST 5 FAILED: stranger insert should have been rejected by RLS';
  END IF;
  RAISE NOTICE 'test_5_stranger_insert_rejected = true';
END $$;

-- ─── TEST 6: active assignee CAN INSERT ─────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000002"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('ffffffff-0003-0000-0000-000000000002', 'task', 'ffffffff-0002-0000-0000-000000000001',
  'assignee-upload.pdf', 'task/ffffffff-0002-0000-0000-000000000001/2-assignee-upload.pdf', 'application/pdf', 2048,
  'ffffffff-0001-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;
SELECT count(*) = 1 AS test_6_assignee_insert_succeeded
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000002';

-- ─── TEST 7: uploader (assignee) CAN DELETE their own file while
--     still an active assignee ──────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000002"}', false);
DELETE FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000002';
SELECT count(*) = 0 AS test_7_assignee_delete_succeeded
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000002';

-- ─── TEST 8: stranger CANNOT DELETE the creator's file ──────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000003"}', false);
DELETE FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';
-- Verified as the CREATOR, not the stranger — the stranger can't
-- SELECT this private-visibility attachment either way (TEST 3), so a
-- count taken while still impersonating them would read 0 whether the
-- DELETE was blocked or had actually succeeded. This is the real,
-- unambiguous check.
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000001"}', false);
SELECT count(*) = 1 AS test_8_stranger_delete_blocked
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000001';

-- ─── TEST 9: uploader who is later UNASSIGNED, and is not
--     creator/supervisor/admin, can no longer delete their own
--     upload (delete authorization is re-checked live, not frozen
--     at upload time) ────────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000002"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('ffffffff-0003-0000-0000-000000000003', 'task', 'ffffffff-0002-0000-0000-000000000001',
  'about-to-lose-access.pdf', 'task/ffffffff-0002-0000-0000-000000000001/3-x.pdf', 'application/pdf', 100,
  'ffffffff-0001-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;
RESET ROLE;
UPDATE task_assignments SET is_active = FALSE
  WHERE task_id = 'ffffffff-0002-0000-0000-000000000001' AND user_id = 'ffffffff-0001-0000-0000-000000000002';
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"ffffffff-0001-0000-0000-000000000002"}', false);
DELETE FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000003';
SELECT count(*) = 1 AS test_9_unassigned_uploader_delete_blocked
FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000003';

RESET ROLE;
-- Restore/clean up for idempotent re-runs (as superuser again).
UPDATE task_assignments SET is_active = TRUE
  WHERE task_id = 'ffffffff-0002-0000-0000-000000000001' AND user_id = 'ffffffff-0001-0000-0000-000000000002';
DELETE FROM attachments WHERE id = 'ffffffff-0003-0000-0000-000000000003';
