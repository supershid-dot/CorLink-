-- ─── Validation: Meeting Attendance Marking ─────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-attendance.sql has been applied there, to confirm
-- the migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- Phase A and docs/23-rooms-meetings-implementation-specification.md
-- "Phase A — RSVP response + attendance marking" §2-§4 (attendance
-- half only — RSVP is covered by validate-meetings-rsvp.sql).

-- ─── 1. Attendance columns present, correct type ───────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants'
  AND column_name IN ('attendance_marked_by', 'attendance_marked_at', 'attendance_note')
ORDER BY column_name;
-- Expect: 3 rows — attendance_marked_at (timestamp with time zone,
-- nullable), attendance_marked_by (uuid, nullable), attendance_note
-- (text, nullable).

SELECT COUNT(*) AS column_count FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants';
-- Expect: 22 (19 per validate-meetings-rsvp.sql's own baseline, plus
-- attendance_marked_by, attendance_marked_at, attendance_note).

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'meeting_participants_attendance_marked_pair_check';
-- Expect: 1 row, definition equivalent to
-- ((attendance_marked_by IS NULL) = (attendance_marked_at IS NULL)).

-- ─── 2. meeting_participant_list() has exactly one overload, ───
-- ─── with attendance_note in its return columns ────────────────
SELECT proname, COUNT(*) FROM pg_proc
WHERE proname = 'meeting_participant_list'
GROUP BY proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows.

SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = 'meeting_participant_list';
-- Expect: return signature includes "attendance_note text" between
-- attendance_status and is_organizer.

-- ─── 3. mark_attendance() exists, SECURITY DEFINER, search_path ─
-- ─── pinned ──────────────────────────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'mark_attendance';
-- Expect: 1 row, prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp'.

-- ─── 4. No RLS policy change on meeting_participants ───────────
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'meeting_participants' ORDER BY policyname;
-- Expect: exactly the same single row as before this patch —
-- "meeting_participants_select", cmd = SELECT. No INSERT/UPDATE/DELETE
-- policy exists for any role; mark_attendance is the only path that
-- can ever change attendance_status/attendance_marked_by/
-- attendance_marked_at/attendance_note.

-- ─── 5. CHECK constraint extended correctly (full accumulated ──
-- ─── list, not a bare addition — docs/23 §0's coordination note) ──
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'attendance_marked' alongside every pre-existing
-- value (including 'invitation_responded' from the RSVP patch).

-- ─── 6. notifications.type UNCHANGED by this patch ─────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-rsvp.sql — no new value added here, since the
-- implementation specification does not call for an attendance
-- notification.

-- ─── 7. Functional test — manager-only, matrix of cases ────────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context), against a meeting with
-- at least one non-manager internal participant:
--   a) As the meeting creator (a manager): SELECT mark_attendance(<participant_id>, 'attended', 'On time');
--      Expect: succeeds, attendance_status='attended',
--      attendance_marked_by=<creator's id>, attendance_marked_at set,
--      attendance_note='On time'.
--   b) As the participant themselves (NOT a manager, marking their
--      own attendance): SELECT mark_attendance(<own_participant_id>, 'attended');
--      Expect: raises "Not authorized to mark attendance for this meeting"
--      (participants cannot self-mark — manager-only, the deliberate
--      inverse of respond_to_invitation's own-row-only rule).
--   c) As the creator: SELECT mark_attendance(<participant_id>, 'unknown');
--      Expect: raises "Invalid attendance status: unknown (expected
--      attended, absent, or excused)" — 'unknown' is not a settable
--      input, only the derived default.
--   d) Mark attendance on a participant belonging to a cancelled
--      meeting. Expect: raises "Cannot mark attendance on a cancelled
--      meeting".
--   e) Mark attendance on a removed (removed_at IS NOT NULL)
--      participant row. Expect: raises "This participant record has
--      been removed".
--   f) Confirm exactly one audit_logs row was inserted for case (a):
-- SELECT COUNT(*) FROM audit_logs
--   WHERE action = 'attendance_marked' AND record_type = 'meeting' AND record_id = <meeting_id>;
--      Expect: 1 per successful call.
--   g) Confirm zero notifications rows were inserted for case (a) —
--      this feature intentionally fires none:
-- SELECT COUNT(*) FROM notifications WHERE record_id = <meeting_id>
--   AND created_at > <timestamp just before case (a) ran>;
--      Expect: 0.
--   h) Re-run respond_to_invitation on the same participant row used
--      in case (a) and confirm attendance_status/attendance_marked_by/
--      attendance_marked_at/attendance_note are UNCHANGED — RSVP and
--      attendance are fully independent columns, neither RPC touches
--      the other's fields.

-- ─── 8. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-attendance.sql a second time against the same
-- project, then re-run checks 1, 2, 3, 5 above — all must return
-- identical results, and any attendance_status/attendance_note value
-- already set by check 7 must be unchanged (the patch contains no
-- seed/UPDATE statement touching existing rows, only DDL and function
-- definitions).
