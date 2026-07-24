-- ─── Validation: Meeting Locking ────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-lock.sql has been applied there, to confirm the
-- migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- Phase B and docs/23-rooms-meetings-implementation-specification.md
-- "Phase B — Meeting minutes, personal notes, and meeting lock" §2-§4
-- (lock portion only — minutes was already shipped separately by
-- patch-meetings-minutes.sql, and personal notes is not implemented
-- by this patch and is not covered here).

-- ─── 1. Lock columns present, correct type ──────────────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings'
  AND column_name IN ('is_locked', 'locked_by', 'locked_at')
ORDER BY column_name;
-- Expect: 3 rows — is_locked (boolean, NOT NULL — is_nullable='NO'),
-- locked_at (timestamp with time zone, nullable), locked_by (uuid,
-- nullable).

SELECT column_default FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings' AND column_name = 'is_locked';
-- Expect: 'false' (the DEFAULT FALSE clause).

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'meetings_lock_alignment_check';
-- Expect: 1 row, definition equivalent to
-- ((is_locked = true) = ((locked_by IS NOT NULL) AND (locked_at IS NOT NULL))).

-- ─── 2. personal_notes is ABSENT — confirms this patch's ────────
-- ─── deliberately narrow scope ───────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_participants' AND column_name = 'personal_notes';
-- Expect: 0 rows — personal participant notes are not part of this feature.

-- ─── 3. New/modified functions exist, SECURITY DEFINER, ────────
-- ─── search_path pinned ──────────────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'is_meeting_lock_overridable', 'lock_meeting', 'unlock_meeting',
  'update_meeting', 'cancel_meeting', 'add_participant', 'remove_participant',
  'assign_room_booking', 'detach_room_booking', 'mark_attendance',
  'update_minutes', 'finalize_minutes', 'cancel_booking', 'reschedule_booking'
)
ORDER BY p.proname;
-- Expect: 14 rows, all prosecdef = true, all proconfig containing
-- 'search_path=public, pg_temp'. is_meeting_lock_overridable is the
-- only STABLE (non-mutating) one of the set; that doesn't change
-- prosecdef/proconfig, so this single query still covers it.

-- Single overload each — confirms no stray extra signature was left
-- behind by any prior DROP FUNCTION/CREATE OR REPLACE cycle in this
-- module.
SELECT p.proname, COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'is_meeting_lock_overridable', 'lock_meeting', 'unlock_meeting',
  'update_meeting', 'cancel_meeting', 'add_participant', 'remove_participant',
  'assign_room_booking', 'detach_room_booking', 'mark_attendance',
  'update_minutes', 'finalize_minutes', 'cancel_booking', 'reschedule_booking'
)
GROUP BY p.proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows.

-- ─── 4. No RLS policy change on meetings/meeting_participants ──
SELECT policyname, cmd FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants') ORDER BY tablename, policyname;
-- Expect: exactly the same two single SELECT-only rows as before
-- this patch ("meetings_select", "meeting_participants_select") —
-- requirement 9: direct table writes remain blocked by RLS; every
-- mutation still goes exclusively through a SECURITY DEFINER RPC.

-- attachments_insert/attachments_delete were restated (not added) —
-- confirm exactly one row each still exists.
SELECT policyname, cmd, COUNT(*) FROM pg_policies
WHERE tablename = 'attachments' AND policyname IN ('attachments_insert', 'attachments_delete')
GROUP BY policyname, cmd;
-- Expect: 2 rows, count 1 each.

-- ─── 5. CHECK constraint extended correctly (full accumulated ──
-- ─── list, not a bare addition — docs/23 §0's coordination note) ──
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'meeting_locked' and 'meeting_unlocked' alongside
-- every pre-existing value (including 'minutes_updated' and
-- 'minutes_finalized' from the minutes patch).

-- ─── 6. notifications.type UNCHANGED by this patch ─────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-minutes.sql — no new value added here, matching
-- docs/23 §Phase B/§7's recommendation to defer
-- meeting_locked/meeting_unlocked notification types.

-- ─── 7. Functional test — full permission matrix ───────────────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context) against a fixture with:
-- two organizations (org1/org2); in org1: a meeting creator (creator1,
-- plain staff), a same-org supervisor (sup1) who is NOT the creator,
-- a same-org admin (admin1); in org2: an admin (admin2) with no
-- relationship to the meeting; a super admin (superadmin); and an
-- ordinary org1 member with no management authority over the meeting
-- (member1). Also add at least one internal participant and one
-- pending/confirmed room booking (rooms module) linked to the meeting.
--
--   a) As creator1: SELECT lock_meeting(<meeting_id>);
--      Expect: succeeds. is_locked=true, locked_by=creator1's id,
--      locked_at set.
--   b) As creator1 again: SELECT lock_meeting(<meeting_id>);
--      Expect: raises "This meeting is already locked".
--   c) As sup1 (can_manage_meeting()=true, NOT overridable):
--      SELECT update_meeting(<meeting_id>, p_title := 'tampered');
--      Expect: raises the locked/not-authorized-to-modify message.
--   d) As sup1: SELECT cancel_meeting(<meeting_id>, 'reason');
--      Expect: raises the locked/not-authorized-to-cancel message.
--   e) As sup1: SELECT add_participant(<meeting_id>, p_external_name := 'X');
--      Expect: raises the locked/not-authorized-to-manage-participants message.
--   f) As sup1: SELECT remove_participant(<some_participant_id>);
--      where that participant is NOT sup1's own row. Expect: raises
--      the locked/not-authorized-to-manage-participants message.
--   g) As the internal participant themselves (own row, not sup1):
--      SELECT remove_participant(<their_own_participant_id>);
--      Expect: ALSO raises the locked message — self-removal is
--      blocked while locked too, per docs/23's literal instruction
--      (this is the one deliberately surprising case; confirm it is
--      not silently allowed).
--   h) As sup1: SELECT mark_attendance(<participant_id>, 'attended');
--      Expect: raises the locked/not-authorized-to-mark-attendance message.
--   i) As sup1: SELECT update_minutes(<meeting_id>, 'tampered');
--      Expect: raises the locked/not-authorized-to-modify-minutes message
--      (even though minutes are not yet finalized — the lock check
--      fires before the finalized/not-finalized tier branch).
--   j) As sup1: SELECT finalize_minutes(<meeting_id>);
--      Expect: raises the locked/not-authorized-to-finalize message.
--   k) As sup1 (also a room manager for the linked booking's room, or
--      is_admin — pick whichever applies in the fixture):
--      SELECT assign_room_booking(<meeting_id>, <another_room_id>);
--      and SELECT detach_room_booking(<meeting_id>);
--      Expect: both raise the locked message.
--   l) As the linked booking's own created_by (may be sup1 or
--      creator1 depending on who assigned it — pick sup1 in the
--      fixture so this is a genuine non-overriding actor):
--      SELECT cancel_booking(<booking_id>); and
--      SELECT reschedule_booking(<booking_id>, p_new_start_at := ...);
--      Expect: both raise the locked message — confirms the
--      booking-level bypass closed in patch section 5 is actually
--      closed, not just the meeting-level RPCs.
--   m) As admin2 (org2 admin, no relationship to this org1 meeting):
--      SELECT unlock_meeting(<meeting_id>);
--      Expect: raises "Not authorized to unlock this meeting" —
--      the explicit cross-org negative test (requirement 5).
--   n) As admin1 (org1 admin, same org as the meeting):
--      SELECT unlock_meeting(<meeting_id>);
--      Expect: succeeds. is_locked=false, locked_by=NULL, locked_at=NULL.
--   o) As creator1: SELECT lock_meeting(<meeting_id>); (re-lock)
--      then as superadmin: SELECT unlock_meeting(<meeting_id>);
--      Expect: succeeds regardless of org.
--   p) As creator1: SELECT lock_meeting(<meeting_id>); (re-lock)
--      then as creator1: SELECT update_meeting(<meeting_id>, p_title := 'ok');
--      and SELECT cancel_meeting(<meeting_id>, NULL);
--      (cancel last, on a fresh un-cancelled fixture meeting if the
--      prior update already consumed this one) — Expect: both
--      succeed — the creator can always manage their own meeting
--      regardless of lock state (requirement 1).
--   q) As member1 (ordinary org1 staff, no management authority at
--      all): SELECT lock_meeting(<meeting_id>);
--      Expect: raises "Only the meeting creator can lock this meeting"
--      (member1 is neither creator nor overridable, but lock_meeting's
--      own creator-only check fires regardless).
--   r) Confirm can_view_meeting()/meeting_participant_list() are
--      completely unaffected by lock state — as sup1 (locked, not
--      overridable): SELECT * FROM meeting_participant_list(<meeting_id>);
--      Expect: succeeds and returns the full participant list exactly
--      as it would if unlocked — requirement 7, read access unchanged.
--   s) Confirm one audit_logs row per successful lock/unlock call
--      above:
-- SELECT action, COUNT(*) FROM audit_logs
--   WHERE record_type = 'meeting' AND record_id = <meeting_id>
--     AND action IN ('meeting_locked', 'meeting_unlocked')
--   GROUP BY action ORDER BY action;
--      Expect: counts matching the number of successful lock/unlock
--      calls in the matrix above.
--   t) Confirm zero notifications rows were inserted by any
--      lock_meeting/unlock_meeting call in this matrix — this
--      feature intentionally fires none (docs/23 §Phase B/§7).

-- ─── 8. Direct table write still rejected (RLS re-confirmation) ─
-- As any authenticated role, attempt:
--   UPDATE meetings SET is_locked = true WHERE id = <meeting_id>;
-- Expect: "permission denied for table meetings" — no UPDATE policy
-- exists on meetings for any role; lock_meeting/unlock_meeting are
-- the only paths that can ever change is_locked/locked_by/locked_at.

-- ─── 9. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-lock.sql a second time against the same
-- project, then re-run checks 1, 3, 4, 5 above — all must return
-- identical results, and any is_locked/locked_by/locked_at value
-- already set by check 7 must be unchanged (the patch contains no
-- seed/UPDATE statement touching existing rows, only DDL and
-- function definitions).
