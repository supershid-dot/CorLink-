-- ─── Validation: Recurring Meetings Phase 2 — Notification- ────────
-- ─── Suppression Foundation ─────────────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-notification-suppression.sql has
-- been applied there, to confirm the migration behaved as designed.
-- Every query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new trailing parameter,
-- p_suppress_notification BOOLEAN DEFAULT FALSE, to update_meeting(),
-- cancel_meeting(), and reschedule_booking(). No recurring-series
-- Phase 2 RPC (create_series_exception, update_entire_series,
-- update_series_this_and_future, cancel_entire_series,
-- cancel_series_this_and_future, can_manage_series) is implemented by
-- this patch or validated here.

-- ─── 1. Exactly one overload of each modified function exists ──────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'update_meeting', 'cancel_meeting', 'reschedule_booking'
)
GROUP BY p.proname ORDER BY p.proname;
-- Expect: exactly 1 row per function, each count = 1 (confirmed
-- empirically — see §6 below). No legacy overload left behind by
-- either DROP FUNCTION statement.

-- ─── 2. Every modified function stays SECURITY DEFINER with ────────
-- ─── search_path pinned ─────────────────────────────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'update_meeting', 'cancel_meeting', 'reschedule_booking'
)
ORDER BY p.proname;
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp' for all 3.

-- ─── 3. Exact new signatures ─────────────────────────────────────────
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'update_meeting', 'cancel_meeting', 'reschedule_booking'
)
ORDER BY p.proname;
-- Expect (each ending in the new trailing parameter):
--   cancel_meeting: p_meeting_id uuid, p_cancellation_reason text,
--     p_suppress_notification boolean
--   reschedule_booking: p_booking_id uuid, p_new_room_id uuid,
--     p_new_start_at timestamp with time zone,
--     p_new_end_at timestamp with time zone, p_new_timezone text,
--     p_suppress_notification boolean
--   update_meeting: p_meeting_id uuid, p_title text,
--     p_description text, p_meeting_type text, p_visibility text,
--     p_status text, p_start_at timestamp with time zone,
--     p_end_at timestamp with time zone, p_timezone text,
--     p_location_mode text, p_external_location text,
--     p_virtual_link text, p_suppress_notification boolean

-- ─── 4. RLS unchanged — no new policy, no direct-write policy ──────
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set — SELECT-only for every
-- table, no INSERT/UPDATE/DELETE policy added by this patch (it never
-- issues an ALTER TABLE ... ENABLE ROW LEVEL SECURITY or CREATE POLICY
-- statement at all).

-- ─── 5. audit_logs / notifications CHECK constraints byte-for-byte ──
-- ─── unchanged — no new audit action or notification type ─────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both identical to their state after patch-meetings-drafts.sql
-- — this patch contains no ALTER TABLE ... ADD CONSTRAINT statement of
-- any kind. Confirmed empirically (§6.G3) that neither constraint
-- contains any Phase-2/series-specific value (those belong to the
-- not-yet-implemented series RPCs).

-- ─── 6. Functional test — empirically verified via local Postgres ──
-- ─── (schema.sql + rls.sql + security-functions.sql, then the full ────
-- ─── rooms/meetings patch chain through patch-meetings-drafts.sql, ────
-- ─── then this patch; hex-only UUID fixtures; SET ROLE authenticated ──
-- ─── + request.jwt.claim.sub per test) — summary for reference: ───────
--
--   A) Legacy update_meeting() call with no p_suppress_notification
--      argument: succeeds; fires exactly 1 meeting_updated
--      notification to the meeting's other participant; writes
--      exactly 1 'edited'/'meeting' audit_logs row — byte-for-byte
--      the pre-patch behavior.
--   B) update_meeting(..., p_suppress_notification := true) on a
--      meeting with a linked confirmed room booking, changing the
--      meeting's time: mutation succeeds (title/time updated); the
--      linked booking's own reschedule still occurs (start_at moved);
--      zero meeting_updated notifications; zero nested booking_changed
--      notifications (propagation into reschedule_booking() confirmed
--      — requirement 5); the meeting's 'edited' audit row and the
--      booking's 'rescheduled' audit row are both still written,
--      unconditionally.
--   C) Legacy cancel_meeting() call with no p_suppress_notification
--      argument, on a meeting with a linked confirmed booking:
--      succeeds; meeting and booking both become 'cancelled'; fires
--      exactly 1 meeting_cancelled notification to the other
--      participant; both the meeting's and the booking's 'cancelled'
--      audit rows are written — byte-for-byte the pre-patch behavior.
--   D) cancel_meeting(..., p_suppress_notification := true) on an
--      equivalent meeting+booking: succeeds; meeting and booking both
--      become 'cancelled'; zero meeting_cancelled notifications; both
--      audit rows still written unconditionally. (cancel_meeting() has
--      no nested notification-producing RPC call to propagate into —
--      its linked-booking cancellation is a direct inline UPDATE, not
--      a call to cancel_booking() or any other RPC, confirmed by
--      inspection and unaffected by this patch.)
--   E) Legacy reschedule_booking() call with no p_suppress_notification
--      argument, on a standalone (non-meeting-linked) booking
--      rescheduled by its own creator: succeeds; fires exactly 1
--      booking_changed notification to the room's manager; writes
--      exactly 1 'rescheduled'/'meeting_room_booking' audit row —
--      byte-for-byte the pre-patch behavior.
--   F) reschedule_booking(..., p_suppress_notification := true) on an
--      equivalent standalone booking: succeeds; zero booking_changed
--      notifications; the 'rescheduled' audit row is still written
--      unconditionally.
--   F2) Room-conflict enforcement is completely independent of the
--      suppression flag: attempting to reschedule a booking (with
--      p_suppress_notification := true) into a time slot already
--      occupied by another confirmed booking on the same room raises
--      the same 'Booking conflict' exception as always (from the
--      pre-existing EXCLUDE-constraint-plus-trigger mechanism on
--      meeting_room_bookings, untouched by this patch), and the
--      target booking's start_at is confirmed unchanged afterward —
--      the mutation did not partially apply.
--   G1) A cross-organization outsider calling
--      update_meeting(..., p_suppress_notification := true) on a
--      meeting they cannot manage is rejected with "Not authorized to
--      update this meeting"; the meeting's title is confirmed
--      unchanged — organization isolation and permission checks are
--      unaffected by the suppression flag.
--   G2) A same-org supervisor (can_manage_meeting()-true but not
--      lock-override-capable) calling
--      update_meeting(..., p_suppress_notification := true) on a
--      locked meeting they do not own is rejected with the same
--      locked-meeting exception as always; the title is confirmed
--      unchanged.
--   G2b) The meeting's own creator (lock-override-capable) CAN still
--      call update_meeting(..., p_suppress_notification := true) on
--      the same locked meeting and succeeds — confirming the
--      suppression flag does not itself grant or remove any
--      permission; lock-override eligibility is entirely unaffected.
--   G3) pg_get_constraintdef() confirms neither audit_logs_action_check
--      nor notifications_type_check contains any Phase-2/series-
--      specific value (e.g. 'meeting_series_updated',
--      'recurring_booking_changed') — this patch introduces no new
--      audit action or notification type, exactly as scoped.
--   G4) Overload counts for all three modified functions are exactly
--      1 each after the patch — no duplicate/legacy overload left
--      ambiguous by either DROP FUNCTION statement.
--   (Regression) Draft-meeting behavior (patch-meetings-drafts.sql,
--      unmodified body sections) re-verified end-to-end after this
--      patch: create_meeting(p_status:='draft') + add_participant()
--      still produce zero notifications; cancel_meeting() still
--      rejects a draft outright with its existing error message;
--      activating a draft via update_meeting(p_status:='scheduled')
--      (not suppressed) still fires exactly 1 meeting_created
--      notification — the draft-specific guards added by
--      patch-meetings-drafts.sql are fully intact under the new
--      signature.

-- ─── 7. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-notification-suppression.sql
-- a second time against the same project, then re-run checks 1–5
-- above — all must return identical results. The patch contains no
-- seed/UPDATE statement against existing rows, only DROP FUNCTION +
-- CREATE OR REPLACE FUNCTION pairs, both idempotent by construction.
