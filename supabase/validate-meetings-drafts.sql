-- ─── Validation: Draft / Pre-booked Meetings ─────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-drafts.sql has been applied there, to confirm the
-- migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data.
--
-- Corresponds to the Draft/Pre-booked Meetings implementation task
-- (docs/22 §3.3 Q4, docs/23 Phase F's draft half).

-- ─── 1. Exactly one overload of each modified/new function exists ──
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'update_meeting', 'cancel_meeting', 'add_participant', 'remove_participant',
  'assign_room_booking', 'respond_to_invitation', 'mark_attendance',
  'update_minutes', 'finalize_minutes', 'lock_meeting', 'delete_draft_meeting'
)
GROUP BY p.proname ORDER BY p.proname;
-- Expect: exactly 1 row per function, each count = 1 (confirmed
-- empirically — see §6 below).

-- ─── 2. Every modified/new function stays SECURITY DEFINER with ──
-- ─── search_path pinned ────────────────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'update_meeting', 'cancel_meeting', 'add_participant', 'remove_participant',
  'assign_room_booking', 'respond_to_invitation', 'mark_attendance',
  'update_minutes', 'finalize_minutes', 'lock_meeting', 'delete_draft_meeting'
)
ORDER BY p.proname;
-- Expect: prosecdef = true, proconfig containing 'search_path=public, pg_temp' for all 11.

-- ─── 3. RLS unchanged — no new policy, no direct-write policy ──────
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants', 'attachments', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set — meetings/meeting_participants
-- remain SELECT-only (no INSERT/UPDATE/DELETE policy for any role,
-- including the new delete_draft_meeting path, which goes through a
-- SECURITY DEFINER function, not a table-level DELETE policy).

-- ─── 4. audit_logs CHECK extended correctly (full accumulated ────
-- ─── list, not a bare addition) ─────────────────────────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'meeting_draft_deleted' alongside every pre-existing
-- value (including 'meeting_series_created', 'meeting_group_*').

-- ─── 5. notifications.type CHECK UNCHANGED — this feature introduces ──
-- ─── no new notification type, only suppresses existing ones ──────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: byte-for-byte identical to its state after
-- patch-meetings-recurring-notifications.sql.

-- ─── 6. Functional test — empirically verified via local Postgres ──
-- ─── (schema.sql + rls.sql + security-functions.sql, then the full ────
-- ─── rooms/meetings patch chain through patch-meetings-recurring- ─────
-- ─── notifications.sql, then this patch; hex-only UUID fixtures; ──────
-- ─── SET ROLE authenticated + request.jwt.claim.sub per test) — ───────
-- ─── summary for reference: ────────────────────────────────────────────
--   a) create_meeting(p_status := 'draft') creates a meeting with
--      status='draft' and produces zero notifications.
--   b) The creator can edit the draft via update_meeting (title,
--      description) — succeeds, no notification, even after a second
--      participant has been added.
--   c) add_participant() on a draft succeeds (participants are
--      allowed on a draft per docs/22 Q4) and produces zero
--      notifications to the added user, confirmed both immediately
--      after adding and after a subsequent draft edit (regression
--      check for the v_new_status = 'scheduled' guard on
--      update_meeting's meaningful-change notification branch).
--   d) respond_to_invitation() on a draft's participant row is
--      rejected ("Cannot respond to an invitation for a draft
--      meeting") — requirement 6.
--   e) mark_attendance() on a draft is rejected ("Cannot mark
--      attendance on a draft meeting") — requirement 7.
--   f) update_minutes() AND finalize_minutes() on a draft are both
--      rejected ("Cannot update/finalize minutes on a draft
--      meeting") — requirement 8.
--   g) lock_meeting() on a draft is rejected ("Cannot lock a draft
--      meeting") — requirement 9.
--   h) cancel_meeting() on a draft is rejected ("Cannot cancel a
--      draft meeting — delete it instead using delete_draft_meeting")
--      — the participant-notification leak this closes (§header note
--      #7), verified by the error firing before any notification
--      INSERT is reached.
--   i) assign_room_booking() on a draft, called by a non-room-manager
--      creator: creates a 'pending' meeting_room_bookings row; the
--      room manager receives exactly 1 'booking_submitted'
--      notification (deliberately unsuppressed); the draft's other
--      participant receives zero 'room_assigned' notifications
--      (requirement 3 + requirement 5, independently verified for
--      each audience) — requirement 5's suppression and the room-
--      manager-notification preservation decision (§header note #2)
--      confirmed as two independently correct outcomes from the same
--      call.
--   j) A user in a different organization: sees zero rows for the
--      draft via a plain SELECT (existing meetings_select/
--      can_view_meeting RLS, unmodified — requirement 13 org
--      isolation); update_meeting() on that draft raises "Not
--      authorized to update this meeting"; delete_draft_meeting() on
--      that draft raises "Not authorized to delete this draft
--      meeting" — requirement re: unauthorized access rejected.
--   k) A direct `UPDATE meetings SET title = title WHERE id = ...`
--      issued as the authenticated creator (bypassing every RPC)
--      affects exactly 0 rows — meetings has no UPDATE policy, so RLS
--      silently filters it to nothing, exactly as every other
--      meeting mutation already only works through an RPC —
--      requirement re: direct writes rejected.
--   l) Activating a draft (update_meeting(p_status := 'scheduled'))
--      preserves the same meeting id (confirmed by re-selecting the
--      same id post-activation) and fires exactly one
--      'meeting_created' notification to the draft's other
--      participant — the "announce now" moment, requirements 10/11.
--   m) After activation, the now-scheduled meeting behaves with zero
--      regression: respond_to_invitation() succeeds and sets
--      invitation_status='accepted'; lock_meeting()/unlock_meeting()
--      both succeed for the creator.
--   n) delete_draft_meeting(): the creator can delete their own
--      draft; a different organization's user cannot; calling it
--      against an already-scheduled meeting is rejected ("Only a
--      draft meeting can be deleted this way..."). After a successful
--      delete: the meetings row is gone (count 0), its
--      meeting_participants rows are gone via cascade (count 0), and
--      a meeting_room_bookings row that had been attached to it still
--      exists (booking history preserved) with status='cancelled' and
--      meeting_id set to NULL (decoupled, not deleted) — requirement
--      re: delete draft, and the FK-RESTRICT-avoidance design in
--      §header note #8.
--   o) An anonymous (unauthenticated) caller of create_meeting is
--      rejected ("create_meeting requires an authenticated caller").
--   p) Exactly one overload exists for every one of the 11
--      redefined/new functions (§1 above, confirmed via
--      pg_proc/pg_namespace) — no ambiguous old+new signature pair
--      left behind by any of this patch's CREATE OR REPLACE
--      statements (none of them changed a signature, so none needed a
--      DROP FUNCTION, and none produced a duplicate).

-- ─── 7. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-drafts.sql a second time against the same
-- project, then re-run checks 1–5 above — all must return identical
-- results, and no existing meetings/meeting_participants/
-- meeting_room_bookings/audit_logs row is touched (the patch contains
-- no seed/UPDATE statement against existing rows, only CREATE OR
-- REPLACE FUNCTION and one CHECK-constraint restatement).
