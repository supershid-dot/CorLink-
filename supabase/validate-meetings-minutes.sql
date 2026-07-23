-- ─── Validation: Meeting Minutes ────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-minutes.sql has been applied there, to confirm the
-- migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- Phase B and docs/23-rooms-meetings-implementation-specification.md
-- "Phase B — Meeting minutes, personal notes, and meeting lock" §2-§4
-- (minutes portion only — personal notes and meeting lock are
-- deliberately not implemented by this patch and are not covered
-- here).

-- ─── 1. Minutes columns present, correct type ──────────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings'
  AND column_name IN ('minutes', 'minutes_finalized', 'minutes_updated_by', 'minutes_updated_at')
ORDER BY column_name;
-- Expect: 4 rows — minutes (text, nullable), minutes_finalized
-- (boolean, NOT NULL — is_nullable='NO'), minutes_updated_at
-- (timestamp with time zone, nullable), minutes_updated_by (uuid,
-- nullable).

SELECT column_default FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings' AND column_name = 'minutes_finalized';
-- Expect: 'false' (the DEFAULT FALSE clause).

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'meetings_minutes_finalized_requires_minutes_check';
-- Expect: 1 row, definition equivalent to
-- ((minutes_finalized = false) OR (minutes IS NOT NULL)).

-- ─── 2. is_locked / personal_notes are ABSENT — confirms this ──
-- ─── patch's deliberately narrow scope ──────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings' AND column_name = 'is_locked';
-- Expect: 0 rows — meeting lock is not part of this feature.

SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants' AND column_name = 'personal_notes';
-- Expect: 0 rows — personal participant notes are not part of this feature.

-- ─── 3. update_minutes() / finalize_minutes() exist, SECURITY ──
-- ─── DEFINER, search_path pinned ─────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('update_minutes', 'finalize_minutes')
ORDER BY p.proname;
-- Expect: 2 rows, both prosecdef = true, both proconfig containing
-- 'search_path=public, pg_temp'.

-- ─── 4. No RLS policy change on meetings ───────────────────────
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'meetings' ORDER BY policyname;
-- Expect: exactly the same single row as before this patch —
-- "meetings_select", cmd = SELECT. No INSERT/UPDATE/DELETE policy
-- exists for any role; update_minutes/finalize_minutes are the only
-- paths that can ever change minutes/minutes_finalized/
-- minutes_updated_by/minutes_updated_at.

-- ─── 5. CHECK constraint extended correctly (full accumulated ──
-- ─── list, not a bare addition — docs/23 §0's coordination note) ──
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'minutes_updated' and 'minutes_finalized' alongside
-- every pre-existing value (including 'invitation_responded' and
-- 'attendance_marked' from the RSVP/attendance patches).

-- ─── 6. notifications.type UNCHANGED by this patch ─────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-attendance.sql — no new value added here, since
-- the implementation specification lists minutes notifications as
-- optional/not required and none was requested for this feature.

-- ─── 7. Functional test — manager-then-admin-only, matrix of ───
-- ─── cases ────────────────────────────────────────────────────────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context), against a meeting with
-- a creator, a distinct org supervisor (not the creator), and a
-- distinct org admin:
--   a) As the creator: SELECT update_minutes(<meeting_id>, 'Draft minutes text');
--      Expect: succeeds, minutes set, minutes_updated_by=<creator's
--      id>, minutes_updated_at set, minutes_finalized still false.
--   b) As an ordinary org member with no management authority over
--      this meeting (not creator, not supervisor/admin, not super
--      admin): SELECT update_minutes(<meeting_id>, 'tampered');
--      Expect: raises "Not authorized to edit minutes for this meeting".
--   c) As a supervisor (who is not the creator, but can_manage_meeting()
--      returns true for them via org-wide supervisor authority):
--      SELECT finalize_minutes(<meeting_id>);
--      Expect: succeeds, minutes_finalized becomes true.
--   d) As the same creator from (a), now that minutes are finalized:
--      SELECT update_minutes(<meeting_id>, 'trying to edit after finalize');
--      Expect: raises "Minutes have been finalized — only an
--      organization administrator or super administrator may edit
--      them now" (the creator is NOT an org admin in this scenario).
--   e) As an org admin (is_admin() = true, same org as the meeting):
--      SELECT update_minutes(<meeting_id>, 'admin correction after finalize');
--      Expect: succeeds.
--   f) As a super admin: SELECT update_minutes(<meeting_id>, 'super admin edit');
--      Expect: succeeds, regardless of org.
--   g) Attempt SELECT finalize_minutes(<a_different_meeting_id_with_null_minutes>);
--      as its creator/supervisor. Expect: raises "Cannot finalize
--      empty minutes — add minutes first".
--   h) Attempt SELECT finalize_minutes(<meeting_id>); a second time on
--      the already-finalized meeting from (c). Expect: raises
--      "Minutes have already been finalized".
--   i) Attempt either RPC on a cancelled meeting. Expect: both raise
--      their respective "Cannot ... on a cancelled meeting" message.
--   j) Confirm one audit_logs row per successful call above:
-- SELECT action, COUNT(*) FROM audit_logs
--   WHERE record_type = 'meeting' AND record_id = <meeting_id>
--     AND action IN ('minutes_updated', 'minutes_finalized')
--   GROUP BY action ORDER BY action;
--      Expect: minutes_updated count matching the number of successful
--      update_minutes calls above (3 in this matrix: a, e, f);
--      minutes_finalized count = 1 (only case c succeeded).
--   k) Confirm zero notifications rows were inserted by any call in
--      this matrix — this feature intentionally fires none.

-- ─── 8. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-minutes.sql a second time against the same
-- project, then re-run checks 1, 3, 4, 5 above — all must return
-- identical results, and any minutes/minutes_finalized value already
-- set by check 7 must be unchanged (the patch contains no seed/UPDATE
-- statement touching existing rows, only DDL and function
-- definitions).
