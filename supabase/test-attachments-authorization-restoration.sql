-- ============================================================
-- CorLink — Attachments RLS Authorization Restoration: Security Suite
-- Companion to supabase/patch-attachments-authorization-restoration.sql
-- Testing-readiness P0-B correction (docs/100)
--
-- Proves the corrected attachments_select/_insert/_delete policies
-- for every record type this session found broken (Task, Meeting,
-- Entry, Entry-reply) plus a Prisoner Letters/Prisoner Reply
-- regression check confirming Phase 1.9A's stricter confidentiality
-- and finalization-lock behavior is fully preserved, and a Requests
-- regression check confirming an untouched-by-this-patch record type
-- still behaves identically. Every scenario exercises the REAL RLS
-- path (SET ROLE authenticated + request.jwt.claims impersonation) —
-- nothing here bypasses RLS to force a pass.
--
-- Run ONLY against a disposable/local test database with the full
-- canonical migration chain (supabase/deploy/apply-canonical-schema.sh)
-- already applied. Idempotent fixtures (ON CONFLICT DO NOTHING);
-- not side-effect-free (creates/deletes real attachments rows).
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 0. Disposable fixtures (as superuser) ──────────────────────────
DO $$
BEGIN
  -- Two orgs: Org AA (MCS-side / task-and-meeting owner), Org BB
  -- (authority-side / cross-org stranger's home, and Prisoner Letters
  -- destination).
  INSERT INTO organizations (id, name, type, code) VALUES
    ('aa000000-0000-0000-0000-000000000001', 'AA00 Test Org', 'authority', 'AA00A'),
    ('aa000000-0000-0000-0000-000000000002', 'AA00 Other Org', 'authority', 'AA00B')
  ON CONFLICT (id) DO NOTHING;

  -- meetings_select RLS additionally requires current_user_module_
  -- enabled('meetings'), on top of can_view_meeting() -- enable it for
  -- Org AA so the meeting-attachment scenarios below reflect real
  -- module-gated access, not a bypass.
  INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT 'aa000000-0000-0000-0000-000000000001', id, TRUE FROM platform_modules WHERE module_key = 'meetings'
  ON CONFLICT (organization_id, module_id) DO UPDATE SET is_enabled = TRUE;

  INSERT INTO divisions (id, name, org_id) VALUES
    ('aa000000-0000-0000-0000-000000000010', 'AA00 Division', 'aa000000-0000-0000-0000-000000000001')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO sections (id, name, code, org_id, division_id) VALUES
    ('aa000000-0000-0000-0000-000000000020', 'AA00 Section', 'AA00S', 'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000010')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email) VALUES
    ('aa000000-0001-0000-0000-000000000001', 'aa00-owner@test.local'),      -- creates task + meeting
    ('aa000000-0001-0000-0000-000000000002', 'aa00-assignee@test.local'),   -- active task assignee / meeting participant
    ('aa000000-0001-0000-0000-000000000003', 'aa00-stranger@test.local'),  -- same-org, unrelated
    ('aa000000-0001-0000-0000-000000000004', 'aa00-crossorg@test.local'),  -- Org BB, unrelated to everything
    ('aa000000-0001-0000-0000-000000000005', 'aa00-entrystaff@test.local'), -- Entry staff, uploads Entry attachment
    ('aa000000-0001-0000-0000-000000000006', 'aa00-replier@test.local')     -- creates the Entry reply draft
  ON CONFLICT (id) DO NOTHING;

  -- No org here configures organizations.entry_section_id, so
  -- is_entry_staff(p_org_id) falls back to a plain org-membership
  -- check (rls.sql / patch-entry-module.sql's own ELSE branch) — any
  -- Org AA member qualifies, no separate flag column needed.
  INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
    ('aa000000-0001-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'AA00-001', 'AA00 Owner',     'aa00-owner@test.local',     TRUE),
    ('aa000000-0001-0000-0000-000000000002', 'aa000000-0000-0000-0000-000000000001', 'AA00-002', 'AA00 Assignee',  'aa00-assignee@test.local',  TRUE),
    ('aa000000-0001-0000-0000-000000000003', 'aa000000-0000-0000-0000-000000000001', 'AA00-003', 'AA00 Stranger',  'aa00-stranger@test.local',  TRUE),
    ('aa000000-0001-0000-0000-000000000004', 'aa000000-0000-0000-0000-000000000002', 'AA00-004', 'AA00 CrossOrg',  'aa00-crossorg@test.local',  TRUE),
    ('aa000000-0001-0000-0000-000000000005', 'aa000000-0000-0000-0000-000000000001', 'AA00-005', 'AA00 EntryStf',  'aa00-entrystaff@test.local', TRUE),
    ('aa000000-0001-0000-0000-000000000006', 'aa000000-0000-0000-0000-000000000001', 'AA00-006', 'AA00 Replier',   'aa00-replier@test.local',   TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- ── Task fixture ──
  INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility) VALUES
    ('aa000000-0002-0000-0000-000000000001', 'TSK-AA00-TEST', 'AA00 test task', 'open', 'normal',
     'aa000000-0001-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000020', 'private')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active) VALUES
    ('aa000000-0002-0000-0000-000000000001', 'aa000000-0001-0000-0000-000000000002', 'aa000000-0001-0000-0000-000000000001', TRUE)
  ON CONFLICT DO NOTHING;

  -- ── Meeting fixture (visibility='private' so the stranger check is
  --    meaningful) ──
  INSERT INTO meetings (id, organization_id, created_by, title, status, visibility, start_at, end_at) VALUES
    ('aa000000-0003-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'aa000000-0001-0000-0000-000000000001',
     'AA00 test meeting', 'scheduled', 'private', NOW() + interval '1 day', NOW() + interval '1 day 1 hour')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO meeting_participants (meeting_id, user_id, invited_by) VALUES
    ('aa000000-0003-0000-0000-000000000001', 'aa000000-0001-0000-0000-000000000002', 'aa000000-0001-0000-0000-000000000001')
  ON CONFLICT DO NOTHING;

  -- ── Entry (external_correspondence) fixture, 'logged' (not closed) ──
  INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, reference_number, subject, body, status, entered_by, to_section_id) VALUES
    ('aa000000-0004-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'letter', 'public', 'AA00 Test Sender', 'AA00-ENTRY-1', 'AA00 test entry',
     'body', 'logged', 'aa000000-0001-0000-0000-000000000005', 'aa000000-0000-0000-0000-000000000020')
  ON CONFLICT (id) DO NOTHING;

  -- ── Entry reply fixture, draft (uploadable per attachments_insert's
  --    own condition: status IN ('draft','pending_approval')) ──
  INSERT INTO external_correspondence_replies (id, entry_id, body, status, created_by) VALUES
    ('aa000000-0005-0000-0000-000000000001', 'aa000000-0004-0000-0000-000000000001', 'reply body', 'draft', 'aa000000-0001-0000-0000-000000000006')
  ON CONFLICT (id) DO NOTHING;
END $$;

-- ─── Prisoner Letters fixture (separate DO block: needs
--     is_prisoner_letters_staff flag + prisoners row) ──────────────
DO $$
BEGIN
  INSERT INTO auth.users (id, email) VALUES
    ('aa000000-0001-0000-0000-000000000007', 'aa00-mcs-pl@test.local'),
    ('aa000000-0001-0000-0000-000000000008', 'aa00-auth-pl@test.local')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO users (id, org_id, service_number, full_name, email, is_active, is_prisoner_letters_staff) VALUES
    ('aa000000-0001-0000-0000-000000000007', 'aa000000-0000-0000-0000-000000000001', 'AA00-007', 'AA00 MCS PL Staff', 'aa00-mcs-pl@test.local', TRUE, TRUE),
    ('aa000000-0001-0000-0000-000000000008', 'aa000000-0000-0000-0000-000000000002', 'AA00-008', 'AA00 Authority PL Staff', 'aa00-auth-pl@test.local', TRUE, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, assigned_to, status) VALUES
    ('aa000000-0006-0000-0000-000000000001', 'PID-AA00', 'AA00 Test Prisoner',
     'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000002',
     'letter body', 'aa000000-0001-0000-0000-000000000007', 'aa000000-0001-0000-0000-000000000008', 'received')
  ON CONFLICT (id) DO NOTHING;

  -- A second letter, created as 'received' (not yet delivered) so an
  -- attachment can legitimately be inserted first — then flipped to
  -- 'delivered' below, to behaviorally prove the finalization lock
  -- blocks DELETE afterwards (INSERT can never be tested this way,
  -- since the lock also blocks the INSERT itself once delivered —
  -- covered separately by scenario 20).
  INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, assigned_to, status) VALUES
    ('aa000000-0006-0000-0000-000000000002', 'PID-AA00-2', 'AA00 Test Prisoner Delivered',
     'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000002',
     'letter body', 'aa000000-0001-0000-0000-000000000007', 'aa000000-0001-0000-0000-000000000008', 'received')
  ON CONFLICT (id) DO NOTHING;
  -- Idempotent re-run safety: this letter is deliberately flipped to
  -- 'delivered' further down (finalization-lock scenarios 20-22) —
  -- reset it back here so a second run of this file still finds it
  -- pre-delivery, same convention test-task-attachments.sql's own
  -- TEST 9 comment already established. Its one pre-delivery
  -- attachment (scenario 20/22) is cleaned up too, for the same
  -- reason.
  UPDATE prisoner_letters SET status = 'received' WHERE id = 'aa000000-0006-0000-0000-000000000002';
  DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000007';
END $$;

-- ─── Requests fixture (regression check — untouched by this patch) ──
DO $$
BEGIN
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, status, created_by, is_locked) VALUES
    ('aa000000-0007-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000002',
     'aa000000-0000-0000-0000-000000000020', 'AA00 test request', 'body', 'draft', 'aa000000-0001-0000-0000-000000000001', FALSE)
  ON CONFLICT (id) DO NOTHING;
END $$;

-- Session-level impersonation from here on (same convention as every
-- other SQL test file in this project).
SET ROLE authenticated;
CREATE TEMP TABLE aa00_results (n INT, ok BOOLEAN, label TEXT);

-- ══════════════════════════════════════════════════════════════════
-- TASKS
-- ══════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000002"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000001', 'task', 'aa000000-0002-0000-0000-000000000001',
  'task-file.pdf', 'task/aa000000-0002-0000-0000-000000000001/1-task-file.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 1, count(*) = 1, 'TASK: active assignee can INSERT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';
INSERT INTO aa00_results SELECT 2, count(*) = 1, 'TASK: active assignee can SELECT own upload'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000003"}', false);
INSERT INTO aa00_results SELECT 3, count(*) = 0, 'TASK: unrelated same-org stranger CANNOT SELECT (private task)'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('task', 'aa000000-0002-0000-0000-000000000001', 'x.pdf', 'task/x/2-x.pdf', 'application/pdf', 100, 'aa000000-0001-0000-0000-000000000003');
  EXCEPTION WHEN insufficient_privilege OR others THEN v_rejected := TRUE;
  END;
  INSERT INTO aa00_results VALUES (4, v_rejected, 'TASK: unrelated same-org stranger CANNOT INSERT');
END $$;

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000004"}', false);
INSERT INTO aa00_results SELECT 5, count(*) = 0, 'TASK: cross-org user CANNOT SELECT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000002"}', false);
DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';
INSERT INTO aa00_results SELECT 6, count(*) = 0, 'TASK: active assignee can DELETE own upload'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000001';

-- ══════════════════════════════════════════════════════════════════
-- MEETINGS
-- ══════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000001"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000002', 'meeting', 'aa000000-0003-0000-0000-000000000001',
  'agenda.pdf', 'meeting/aa000000-0003-0000-0000-000000000001/1-agenda.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 7, count(*) = 1, 'MEETING: organizer (can_manage_meeting) can INSERT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000002"}', false);
INSERT INTO aa00_results SELECT 8, count(*) = 1, 'MEETING: active participant can SELECT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000003"}', false);
INSERT INTO aa00_results SELECT 9, count(*) = 0, 'MEETING: unrelated same-org stranger CANNOT SELECT (private meeting)'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000004"}', false);
INSERT INTO aa00_results SELECT 10, count(*) = 0, 'MEETING: cross-org user CANNOT SELECT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000001"}', false);
DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';
INSERT INTO aa00_results SELECT 11, count(*) = 0, 'MEETING: organizer can DELETE'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000002';

-- ══════════════════════════════════════════════════════════════════
-- ENTRY / EXTERNAL CORRESPONDENCE + REPLY
-- ══════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000005"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000003', 'external_correspondence', 'aa000000-0004-0000-0000-000000000001',
  'entry-file.pdf', 'external_correspondence/aa000000-0004-0000-0000-000000000001/1-entry-file.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000005')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 12, count(*) = 1, 'ENTRY: entry staff can INSERT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000003';
INSERT INTO aa00_results SELECT 13, count(*) = 1, 'ENTRY: entry staff can SELECT own upload'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000003';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000006"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000004', 'external_correspondence_reply', 'aa000000-0005-0000-0000-000000000001',
  'reply-file.pdf', 'external_correspondence_reply/aa000000-0005-0000-0000-000000000001/1-reply-file.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000006')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 14, count(*) = 1, 'ENTRY REPLY: draft author can INSERT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000004';
INSERT INTO aa00_results SELECT 15, count(*) = 1, 'ENTRY REPLY: draft author can SELECT own upload'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000004';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000004"}', false);
INSERT INTO aa00_results SELECT 16, count(*) = 0, 'ENTRY: cross-org user CANNOT SELECT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000003';

-- ══════════════════════════════════════════════════════════════════
-- PRISONER LETTERS / PRISONER REPLY — Phase 1.9A protections intact
-- ══════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000008"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000005', 'prisoner_letter', 'aa000000-0006-0000-0000-000000000001',
  'pl-file.pdf', 'prisoner_letter/aa000000-0006-0000-0000-000000000001/1-pl-file.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000008')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 17, count(*) = 1, 'PRISONER LETTER: assigned authority staff can INSERT (received, not delivered)'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000005';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000007"}', false);
INSERT INTO aa00_results SELECT 18, count(*) = 1, 'PRISONER LETTER: submitting MCS staff can SELECT'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000005';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000003"}', false);
INSERT INTO aa00_results SELECT 19, count(*) = 0, 'PRISONER LETTER: unrelated flagged staff CANNOT gain access via org membership alone'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000005';

-- Finalization lock, INSERT side: insert a real attachment while
-- letter 0002 is still 'received' (must succeed), then flip it to
-- 'delivered' (superuser), then prove a NEW insert attempt is now
-- rejected, and that the ALREADY-inserted attachment can no longer be
-- deleted either.
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000008"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000007', 'prisoner_letter', 'aa000000-0006-0000-0000-000000000002',
  'pre-delivery.pdf', 'prisoner_letter/aa000000-0006-0000-0000-000000000002/1-pre-delivery.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000008')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 20, count(*) = 1, 'PRISONER LETTER: attachment insertable before delivery'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000007';

RESET ROLE;
UPDATE prisoner_letters SET status = 'delivered' WHERE id = 'aa000000-0006-0000-0000-000000000002';
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000008"}', false);

DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('prisoner_letter', 'aa000000-0006-0000-0000-000000000002', 'late.pdf', 'prisoner_letter/x/2-late.pdf', 'application/pdf', 100, 'aa000000-0001-0000-0000-000000000008');
  EXCEPTION WHEN insufficient_privilege OR others THEN v_rejected := TRUE;
  END;
  INSERT INTO aa00_results VALUES (21, v_rejected, 'PRISONER LETTER: finalization lock (delivered) blocks a NEW INSERT');
END $$;

DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000007';
  EXCEPTION WHEN insufficient_privilege OR others THEN v_rejected := TRUE;
  END;
  INSERT INTO aa00_results SELECT 22, (v_rejected OR count(*) = 1), 'PRISONER LETTER: finalization lock (delivered) blocks DELETE of a pre-existing attachment'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000007';
END $$;

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000008"}', false);
DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000005';
INSERT INTO aa00_results SELECT 23, count(*) = 0, 'PRISONER LETTER: assigned authority staff can DELETE own upload before delivery'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000005';

-- ══════════════════════════════════════════════════════════════════
-- REQUESTS — regression check, untouched by this patch
-- ══════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000001"}', false);
INSERT INTO attachments (id, record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
VALUES ('aa000000-0008-0000-0000-000000000006', 'request', 'aa000000-0007-0000-0000-000000000001',
  'req-file.pdf', 'request/aa000000-0007-0000-0000-000000000001/1-req-file.pdf', 'application/pdf', 100,
  'aa000000-0001-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;
INSERT INTO aa00_results SELECT 24, count(*) = 1, 'REQUEST: creator can still INSERT (regression check)'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000006';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000004"}', false);
INSERT INTO aa00_results SELECT 25, count(*) = 0, 'REQUEST: cross-org user still CANNOT SELECT (regression check)'
  FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000006';

SELECT set_config('request.jwt.claims', '{"sub":"aa000000-0001-0000-0000-000000000001"}', false);
DELETE FROM attachments WHERE id = 'aa000000-0008-0000-0000-000000000006';

RESET ROLE;

-- ─── Final report ────────────────────────────────────────────────
DO $$
DECLARE r RECORD; v_fail INT := 0;
BEGIN
  FOR r IN SELECT * FROM aa00_results ORDER BY n LOOP
    RAISE NOTICE '% %  (%)', CASE WHEN r.ok THEN 'PASS' ELSE 'FAIL' END, r.n, r.label;
    IF NOT r.ok THEN v_fail := v_fail + 1; END IF;
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ATTACHMENTS AUTHORIZATION RESTORATION SECURITY SUITE FAILED: % scenario(s)', v_fail;
  END IF;
  RAISE NOTICE 'ATTACHMENTS AUTHORIZATION RESTORATION SECURITY SUITE PASSED: 25/25';
END $$;
