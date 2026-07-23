-- ─── Validation: Meeting RSVP Responses ────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-rsvp.sql has been applied there, to confirm the
-- migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- Phase A and docs/23-rooms-meetings-implementation-specification.md
-- "Phase A — RSVP response + attendance marking" §2-§4 (RSVP half only
-- — this patch and this validation script deliberately do not cover
-- attendance marking, a separate feature).

-- ─── 1. invitation_note column present, correct type ───────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants' AND column_name = 'invitation_note';
-- Expect: 1 row, data_type = 'text', is_nullable = 'YES'.

SELECT COUNT(*) AS column_count FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants';
-- Expect: 19 (18 per validate-meetings-foundation.sql's own baseline,
-- plus invitation_note).

-- ─── 2. meeting_participant_list() has exactly one overload, ───
-- ─── with invitation_note in its return columns ────────────────
SELECT proname, COUNT(*) FROM pg_proc
WHERE proname = 'meeting_participant_list'
GROUP BY proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows (confirms the DROP FUNCTION before CREATE OR REPLACE
-- didn't leave a stale/duplicate overload behind).

SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = 'meeting_participant_list';
-- Expect: return signature includes "invitation_note text" between
-- invitation_status and attendance_status.

-- ─── 3. respond_to_invitation() exists, SECURITY DEFINER, ──────
-- ─── search_path pinned ─────────────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'respond_to_invitation';
-- Expect: 1 row, prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp'.

-- ─── 4. No RLS policy change on meeting_participants ───────────
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'meeting_participants' ORDER BY policyname;
-- Expect: exactly the same single row as before this patch —
-- "meeting_participants_select", cmd = SELECT. No INSERT/UPDATE/DELETE
-- policy exists for any role; respond_to_invitation is the only path
-- that can ever change invitation_status/invitation_note.

-- ─── 5. CHECK constraints extended correctly (full accumulated ─
-- ─── list, not a bare addition — docs/23 §0's coordination note) ──
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: includes 'participant_responded' alongside every
-- pre-existing value from patch-meetings-foundation.sql's own list.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'invitation_responded' alongside every pre-existing
-- value.

-- ─── 6. Functional test — own row only, matrix of cases ────────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context), against a meeting with
-- at least one internal participant who is NOT the caller and one who
-- IS the caller:
--   a) SELECT respond_to_invitation(<own_participant_id>, 'accepted', 'See you there');
--      Expect: succeeds, invitation_status='accepted',
--      invitation_note='See you there' on that row only.
--   b) SELECT respond_to_invitation(<someone_else's_participant_id>, 'declined');
--      Expect: raises "Not authorized to respond on behalf of this participant".
--   c) SELECT respond_to_invitation(<own_participant_id>, 'not_required');
--      Expect: raises "Invalid response: not_required (expected accepted or declined)".
--   d) Respond on a participant row belonging to a cancelled meeting.
--      Expect: raises "Cannot respond to a cancelled meeting".
--   e) Respond on a removed (removed_at IS NOT NULL) participant row,
--      even one belonging to the caller.
--      Expect: raises "This participant record has been removed".
--   f) Confirm exactly one notifications row was inserted for case (a)
--      above, addressed to the meeting's created_by (unless the caller
--      IS the created_by, in which case zero rows — self-notification
--      is deliberately skipped):
-- SELECT COUNT(*) FROM notifications
--   WHERE type = 'participant_responded' AND record_id = <meeting_id>;
--      Expect: 1 (or 0 in the self-response case above).
--   g) Confirm exactly one audit_logs row was inserted for case (a):
-- SELECT COUNT(*) FROM audit_logs
--   WHERE action = 'invitation_responded' AND record_type = 'meeting' AND record_id = <meeting_id>;
--      Expect: 1 per successful call.

-- ─── 7. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-rsvp.sql a second time against the same
-- project, then re-run checks 1, 2, 3, 5 above — all must return
-- identical results, and any invitation_status/invitation_note value
-- already set by check 6 must be unchanged (the patch contains no
-- seed/UPDATE statement touching existing rows, only DDL and function
-- definitions, so this is expected to hold trivially — this check
-- confirms that, not assumes it).
