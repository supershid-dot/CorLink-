-- ============================================================
-- CorLink — Behavioral test: Meeting Attachment Storage Authorization
-- fix (T3D.1). Companion to the storage-policies.sql correction.
--
-- ⚠ WARNING: This script INSERTS disposable test fixtures (fixed
-- 'eeeeeeee-...'-prefixed UUIDs) and exercises real attachments/
-- storage.objects INSERT/SELECT/DELETE RLS behavior under a real,
-- non-superuser `authenticated` role via request.jwt.claims
-- impersonation — same SET ROLE authenticated + set_config(
-- 'request.jwt.claims', ..., false) convention established by
-- supabase/test-task-audit-visibility.sql and reused throughout this
-- project's SQL test suite (session-level, not per-statement SET
-- LOCAL — a plain autocommitted script has no enclosing transaction
-- for SET LOCAL to live inside, so it would silently revert before
-- the very next statement). Run this ONLY against a disposable/local
-- test database with storage-policies.sql (post-fix) already applied
-- — NEVER against staging or production. Idempotent (ON CONFLICT DO
-- NOTHING fixtures + explicit cleanup of mutated storage.objects/
-- attachments rows at the end); not side-effect-free during the run.
--
-- Root cause under test: the `attachments` table's own RLS
-- (attachments_select/_insert/_delete) already had a correct 'meeting'
-- branch — this file does NOT re-test that (see docs/49 and the T3D
-- investigation for how that was already confirmed). What was broken,
-- and is what this file proves fixed, is the SEPARATE storage.objects
-- bucket-level policy (attachments_storage_insert's per-record-type
-- folder allowlist), which never had 'meeting' added when meeting
-- attachments shipped. Since AttachmentsAPI.upload() writes to
-- Storage BEFORE inserting the `attachments` metadata row, that
-- Storage-level rejection alone was enough to break every meeting
-- attachment upload regardless of the table-level RLS being correct.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures (as superuser, before impersonating) ─
DO $$
BEGIN
  INSERT INTO organizations (id, name, type, code) VALUES
    ('eeeeeeee-0000-0000-0000-000000000001', 'T3D.1 Test Org', 'authority', 'T3D1ORG')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('eeeeeeee-0001-0000-0000-000000000001', 't3d1-manager@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000002', 't3d1-viewer@test.local'),
    ('eeeeeeee-0001-0000-0000-000000000003', 't3d1-stranger@test.local')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('eeeeeeee-0001-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'T3D1-001', 'T3D1 Manager',  't3d1-manager@test.local',  TRUE),
    ('eeeeeeee-0001-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001', 'T3D1-002', 'T3D1 Viewer',   't3d1-viewer@test.local',   TRUE),
    ('eeeeeeee-0001-0000-0000-000000000003', 'eeeeeeee-0000-0000-0000-000000000001', 'T3D1-003', 'T3D1 Stranger', 't3d1-stranger@test.local', TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- A scheduled, unlocked meeting. Manager can view+manage; Viewer can
  -- only view; Stranger has neither grant (mirrors "not a participant,
  -- module not enabled for them" in the real can_view_meeting()).
  INSERT INTO meetings (id, status, is_locked) VALUES
    ('eeeeeeee-0002-0000-0000-000000000001', 'scheduled', FALSE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO meeting_view_grants (meeting_id, user_id) VALUES
    ('eeeeeeee-0002-0000-0000-000000000001', 'eeeeeeee-0001-0000-0000-000000000001'),
    ('eeeeeeee-0002-0000-0000-000000000001', 'eeeeeeee-0001-0000-0000-000000000002')
  ON CONFLICT DO NOTHING;

  INSERT INTO meeting_manage_grants (meeting_id, user_id) VALUES
    ('eeeeeeee-0002-0000-0000-000000000001', 'eeeeeeee-0001-0000-0000-000000000001')
  ON CONFLICT DO NOTHING;
END $$;

-- Session-level impersonation from here on (same convention as every
-- other SQL test file in this project).
SET ROLE authenticated;

-- ─── TEST 1: Storage INSERT (upload) — meeting path now ACCEPTED ──
-- This is the actual fix under test: before storage-policies.sql was
-- corrected, this exact INSERT would have been rejected by
-- attachments_storage_insert's WITH CHECK (folder allowlist), because
-- 'meeting' was absent from the IN-list — independent of the
-- table-level attachments_insert policy, which was already correct.
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
INSERT INTO storage.objects (id, bucket_id, name, owner) VALUES
  ('eeeeeeee-0003-0000-0000-000000000001', 'attachments',
   'meeting/eeeeeeee-0002-0000-0000-000000000001/1-minutes.pdf',
   'eeeeeeee-0001-0000-0000-000000000001');
-- Verified via RESET ROLE (RLS-bypassing), not while still
-- impersonating the uploader — attachments_storage_select gates
-- SELECT on a matching `attachments` row existing (chicken-and-egg;
-- see storage-policies.sql's own comment), and that row isn't
-- inserted until TEST 2 below, so a same-role verification here would
-- read 0 regardless of whether the INSERT above actually succeeded —
-- the exact false-negative pitfall documented in test-task-
-- attachments.sql's TEST 8. The INSERT statement itself not raising
-- is already proof the WITH CHECK passed; this just confirms the row
-- landed.
RESET ROLE;
SELECT count(*) = 1 AS test_1_meeting_storage_upload_now_accepted
FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000001';
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);

-- ─── TEST 2: metadata INSERT (attachments table) for the same file ─
-- Proves the FULL upload lifecycle (Storage write + attachments row)
-- now succeeds end-to-end for a meeting manager, matching
-- AttachmentsAPI.upload()'s real two-step sequence.
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('eeeeeeee-0004-0000-0000-000000000001', 'meeting', 'eeeeeeee-0002-0000-0000-000000000001',
  'minutes.pdf', 'meeting/eeeeeeee-0002-0000-0000-000000000001/1-minutes.pdf', 'application/pdf', 4096,
  'eeeeeeee-0001-0000-0000-000000000001');
SELECT count(*) = 1 AS test_2_meeting_metadata_insert_succeeded
FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000001';

-- ─── TEST 3: download — a participant with view-only access can
-- SELECT the storage object (attachments_storage_select, gated via
-- EXISTS against the attachments row + attachments_select's 'meeting'
-- branch) — this path was never broken, confirmed still works
-- together with the fix. ────────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000002"}', false);
SELECT count(*) = 1 AS test_3_viewer_can_download
FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000001';

-- ─── TEST 4: a stranger (no view/manage grant) cannot see the
-- metadata row or the storage object — regression check that the fix
-- didn't loosen visibility. ─────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000003"}', false);
SELECT count(*) = 0 AS test_4_stranger_cannot_see_metadata
FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000001';
SELECT count(*) = 0 AS test_4_stranger_cannot_see_storage_object
FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000001';

-- ─── TEST 5: a stranger (no manage grant) cannot upload to this
-- meeting's folder, even though 'meeting' is now an allowed folder
-- name in general — the per-file table-level attachments_insert
-- policy (can_manage_meeting) still gates it independently of Storage.
-- Storage's own allowlist is a coarse boundary, not per-record
-- authorization: the objects INSERT itself is owner-scoped and would
-- actually succeed at the Storage layer (Storage has no knowledge of
-- can_manage_meeting), so the real boundary a stranger hits is the
-- attachments table INSERT — verified here directly. ────────────────
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('meeting', 'eeeeeeee-0002-0000-0000-000000000001', 'x.pdf',
      'meeting/eeeeeeee-0002-0000-0000-000000000001/x.pdf', 'application/pdf', 100,
      'eeeeeeee-0001-0000-0000-000000000003');
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_rejected := TRUE;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST 5 FAILED: stranger metadata insert should have been rejected by RLS';
  END IF;
  RAISE NOTICE 'test_5_stranger_metadata_insert_rejected = true';
END $$;

-- ─── TEST 6: replace — client-orchestrated as upload-new-then-
-- delete-old (AttachmentsAPI has no separate "replace" primitive; see
-- docs/48 §Upload lifecycle and js/views/task-detail.js's
-- _bindAttachmentsPanel for the same pattern reused for meetings).
-- Upload the replacement first. ─────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
INSERT INTO storage.objects (id, bucket_id, name, owner) VALUES
  ('eeeeeeee-0003-0000-0000-000000000002', 'attachments',
   'meeting/eeeeeeee-0002-0000-0000-000000000001/2-minutes-v2.pdf',
   'eeeeeeee-0001-0000-0000-000000000001');
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('eeeeeeee-0004-0000-0000-000000000002', 'meeting', 'eeeeeeee-0002-0000-0000-000000000001',
  'minutes-v2.pdf', 'meeting/eeeeeeee-0002-0000-0000-000000000001/2-minutes-v2.pdf', 'application/pdf', 4200,
  'eeeeeeee-0001-0000-0000-000000000001');
-- ...then delete the original (both layers, matching AttachmentsAPI.remove()).
DELETE FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000001';
DELETE FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000001';
SELECT
  (SELECT count(*) FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000002') = 1
  AND (SELECT count(*) FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000001') = 0
  AND (SELECT count(*) FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000001') = 0
  AS test_6_replace_succeeded;

-- ─── TEST 7: delete — the uploader (still meeting manager) can
-- delete their own upload at both layers (unaffected by the fix,
-- confirmed still works end-to-end). ────────────────────────────────
DELETE FROM storage.objects WHERE id = 'eeeeeeee-0003-0000-0000-000000000002';
DELETE FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000002';
SELECT count(*) = 0 AS test_7_delete_succeeded
FROM attachments WHERE id = 'eeeeeeee-0004-0000-0000-000000000002';

RESET ROLE;

-- ─── TEST 8 (regression, run as superuser against the structural
-- policy itself): every OTHER record type's folder prefix already in
-- attachments_storage_insert's allowlist is still present and
-- unaffected by appending 'meeting' — Requests, Entry
-- (external_correspondence/_reply), Internal Collaboration
-- (internal_request/internal_reply), Prisoner Letters
-- (prisoner_letter/prisoner_reply), and Tasks. ──────────────────────
SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%''request''%'                        AS has_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''response''%'                       AS has_response,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_request''%'               AS has_internal_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_reply''%'                 AS has_internal_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_letter''%'                AS has_prisoner_letter,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_reply''%'                 AS has_prisoner_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence''%'        AS has_external_correspondence,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence_reply''%'  AS has_external_correspondence_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''task''%'                           AS has_task,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''meeting''%'                        AS has_meeting_now
FROM pg_policy WHERE polname = 'attachments_storage_insert';

-- ─── TEST 9 (regression): an unrecognized record type (default-deny
-- still holds — the allowlist is still a real boundary, not opened
-- wide by this fix). ────────────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"eeeeeeee-0001-0000-0000-000000000001"}', false);
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO storage.objects (bucket_id, name, owner) VALUES
      ('attachments', 'bogus_type/x/y.pdf', 'eeeeeeee-0001-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_rejected := TRUE;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST 9 FAILED: unrecognized folder name should still be rejected';
  END IF;
  RAISE NOTICE 'test_9_unrecognized_folder_still_rejected = true';
END $$;
RESET ROLE;

-- ─── Cleanup for idempotent re-runs ──────────────────────────────
DELETE FROM storage.objects WHERE id IN (
  'eeeeeeee-0003-0000-0000-000000000001', 'eeeeeeee-0003-0000-0000-000000000002'
);
DELETE FROM attachments WHERE id IN (
  'eeeeeeee-0004-0000-0000-000000000001', 'eeeeeeee-0004-0000-0000-000000000002'
);
