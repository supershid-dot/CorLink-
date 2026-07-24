-- ─── Validation: Meeting Personal Notes ─────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-personal-notes.sql has been applied there, to
-- confirm the migration behaved as designed. Every query below is a
-- SELECT — nothing here writes data. A query returning zero rows in
-- the "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- Phase B and docs/23-rooms-meetings-implementation-specification.md
-- "Phase B — Meeting minutes, personal notes, and meeting lock"
-- (personal-notes portion only). See patch-meetings-personal-notes.sql's
-- own header for why this uses a dedicated table instead of docs/23's
-- literal "column on meeting_participants" wording.

-- ─── 1. Table + columns present, correct type ───────────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participant_notes'
ORDER BY column_name;
-- Expect: 4 rows — notes (text, nullable), participant_id (uuid, NOT
-- NULL — is the PK), updated_at (timestamp with time zone, nullable),
-- user_id (uuid, NOT NULL).

-- ─── 2. meeting_participants.personal_notes remains ABSENT — ───
-- ─── confirms the dedicated-table design was actually used, not ──
-- ─── a plain column (the regression review's exact prior finding) ─
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants' AND column_name = 'personal_notes';
-- Expect: 0 rows.

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname IN ('meeting_participant_notes_notes_check', 'meeting_participant_notes_alignment_check')
ORDER BY conname;
-- Expect: 2 rows.

-- ─── 3. get_my_notes() / update_my_notes() exist, correct ──────
-- ─── volatility, SECURITY DEFINER, search_path pinned ────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('get_my_notes', 'update_my_notes')
ORDER BY p.proname;
-- Expect: 2 rows, both prosecdef = true, both proconfig containing
-- 'search_path=public, pg_temp'.

SELECT p.proname, COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('get_my_notes', 'update_my_notes')
GROUP BY p.proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows (no stray extra overload from any prior iteration).

-- ─── 4. RLS: strictly own-row, no manager/admin/super-admin ────
-- ─── carve-out anywhere in the policy text ────────────────────────
SELECT policyname, cmd, qual FROM pg_policies
WHERE tablename = 'meeting_participant_notes';
-- Expect: exactly 1 row — "meeting_participant_notes_select", SELECT,
-- qual = (user_id = auth.uid()). No INSERT/UPDATE/DELETE policy
-- exists for any role. The qual text must NOT reference
-- can_manage_meeting, is_admin, or is_super_admin — if it does, the
-- own-row-only guarantee has been weakened.

-- ─── 5. No new audit_logs.action / notifications.type values ───
-- ─── — this feature deliberately adds neither (see the patch ─────
-- ─── file's own reasoning: an audit row would leak edit-metadata ──
-- ─── to org admins/super admins via the general audit_select ─────
-- ─── policy even with no note content in it) ──────────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-lock.sql — no new value added here.
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-attendance.sql — no new value added here.

-- ─── 6. meeting_participant_list() unchanged — confirms personal ──
-- ─── notes were never folded into the general participant list ───
SELECT p.proname, pg_get_function_result(p.oid) AS return_shape
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'meeting_participant_list';
-- Expect: return_shape does NOT mention "notes_private" or
-- "personal_notes" — identical return shape to the one shipped by
-- patch-meetings-attendance.sql (id, user_id, external_name,
-- external_email, external_phone, external_organization_name,
-- participant_role, invitation_status, invitation_note,
-- attendance_status, attendance_note, is_organizer, notes,
-- created_at). Note: the pre-existing "notes" column in that list is
-- meeting_participants.notes (an add-time annotation set by whoever
-- invited the participant, visible to anyone who can already see the
-- row) — a completely different, non-private field from this
-- patch's meeting_participant_notes.notes; the two must never be
-- confused.

-- ─── 7. Functional test — own-row-only matrix ───────────────────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context), against a meeting
-- with: its creator (creator1), an internal participant who is NOT
-- the creator (participant1), a same-org supervisor (sup1, can_
-- manage_meeting()=true), a same-org admin (admin1), a cross-org
-- admin (admin2, different org), and a super admin:
--   a) As participant1 (own row): SELECT update_my_notes(<participant1's
--      own participant_id>, 'My private prep notes');
--      Expect: succeeds.
--   b) As participant1: SELECT get_my_notes(<own participant_id>);
--      Expect: returns 'My private prep notes'.
--   c) As participant1: SELECT update_my_notes(<own participant_id>,
--      'Updated notes');
--      Expect: succeeds; (b) re-run now returns 'Updated notes'.
--   d) As participant1: SELECT update_my_notes(<own participant_id>, '');
--      (or NULL) Expect: succeeds; (b) re-run now returns NULL
--      (cleared).
--   e) As a DIFFERENT internal participant (participant2, not
--      participant1): SELECT get_my_notes(<participant1's participant_id>);
--      Expect: raises "Not authorized to view these notes".
--   f) As participant2: SELECT update_my_notes(<participant1's
--      participant_id>, 'tampered');
--      Expect: raises "Not authorized to update these notes".
--   g) As creator1 (NOT participant1, even though creator1 is
--      can_manage_meeting()=true for this meeting):
--      SELECT get_my_notes(<participant1's participant_id>);
--      Expect: raises "Not authorized to view these notes" — the
--      creator has ZERO special access to another participant's
--      notes (requirement 3).
--   h) As sup1 (can_manage_meeting()=true, not participant1):
--      SELECT get_my_notes(<participant1's participant_id>);
--      Expect: raises "Not authorized to view these notes"
--      (requirement 4).
--   i) As admin1 (same-org admin, not participant1):
--      SELECT get_my_notes(<participant1's participant_id>);
--      Expect: raises "Not authorized to view these notes"
--      (requirement 5 — same-org admin still has no exception).
--   j) As admin2 (cross-org admin): SELECT get_my_notes(<participant1's
--      participant_id>);
--      Expect: raises "Not authorized to view these notes" (the
--      explicit cross-org negative test, requirement 5).
--   k) As super admin: SELECT get_my_notes(<participant1's participant_id>);
--      Expect: raises "Not authorized to view these notes" —
--      confirms docs/23 defines NO super-admin exception for
--      personal notes (requirement 6), unlike minutes/lock override.
--   l) Unauthenticated (no request.jwt.claim.sub set at all, so
--      auth.uid() is NULL): SELECT get_my_notes(<any participant_id>);
--      and SELECT update_my_notes(<any participant_id>, 'x');
--      Expect: both raise "requires an authenticated caller".
--   m) Remove participant1 from the meeting (as sup1, via
--      remove_participant), then as participant1:
--      SELECT get_my_notes(<own participant_id>);
--      Expect: still succeeds (own historical notes remain readable
--      after removal — reads are never lifecycle-gated).
--      Then SELECT update_my_notes(<own participant_id>, 'after removal');
--      Expect: raises "This participant record has been removed".
--   n) On a SEPARATE, cancelled meeting with its own participant:
--      as that participant, SELECT get_my_notes(<own participant_id>);
--      Expect: succeeds (reads never blocked by meeting status).
--      SELECT update_my_notes(<own participant_id>, 'after cancel');
--      Expect: raises "Cannot update notes on a cancelled meeting".
--   o) On a THIRD, LOCKED meeting (locked by its creator via
--      lock_meeting) with its own non-creator participant: as that
--      participant, SELECT update_my_notes(<own participant_id>,
--      'while locked'); Expect: SUCCEEDS — locking must never block
--      a participant's own notes (this feature's explicit
--      requirement, mirroring respond_to_invitation's identical
--      carve-out already proven in validate-meetings-lock.sql).
--   p) Confirm meeting_participant_list(<meeting_id>) called by ANY
--      caller (including sup1/admin1/super admin) never returns any
--      column containing participant1's note text — inspect the
--      full row shape returned and confirm 'My private prep notes'/
--      'Updated notes' never appears anywhere in it.
--   q) Confirm zero audit_logs rows were inserted by any
--      get_my_notes/update_my_notes call in this matrix:
-- SELECT COUNT(*) FROM audit_logs WHERE action = 'personal_notes_updated';
--      Expect: 0 (this action value doesn't even exist in the CHECK
--      constraint, so this is a defense-in-depth confirmation, not
--      just a count).
--   r) Confirm zero notifications rows were inserted by any call in
--      this matrix.

-- ─── 8. Direct table write still rejected by RLS ───────────────
-- As participant1 (own row): attempt
--   INSERT INTO meeting_participant_notes (participant_id, user_id, notes)
--     VALUES (<own participant_id>, auth.uid(), 'direct insert attempt');
-- Expect: "permission denied for table meeting_participant_notes" —
-- no INSERT/UPDATE/DELETE policy exists for any role; update_my_notes
-- is the only path that can ever write this table.

-- ─── 9. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-personal-notes.sql a second time against the
-- same project, then re-run checks 1, 3, 4, 5 above — all must
-- return identical results, and any notes value already set by
-- check 7 must be unchanged (the patch contains no seed/UPDATE
-- statement touching existing rows, only DDL and function
-- definitions).
