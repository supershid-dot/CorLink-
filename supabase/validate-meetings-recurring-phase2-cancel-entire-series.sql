-- ─── Validation: Recurring Meetings Phase 2 — Cancel Entire Series ──
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-cancel-entire-series.sql has been
-- applied there, to confirm the migration behaved as designed. Every
-- query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- cancel_entire_series(p_series_id, p_cancellation_reason) RETURNS
-- TABLE(meeting_id, occurrence_date, outcome), plus two CHECK-
-- constraint restatements adding 'meeting_series_cancelled'.
-- cancel_series_this_and_future() is not implemented here.

-- ─── 1. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_entire_series'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── 2. SECURITY DEFINER with search_path pinned ────────────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_entire_series';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 'v'.

-- ─── 3. Exact signature ──────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_entire_series';
-- Expect: args = 'p_series_id uuid, p_cancellation_reason text',
-- ret = 'TABLE(meeting_id uuid, occurrence_date date, outcome text)'.

-- ─── 4. RLS and schema unchanged beyond the two CHECK restatements ──
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meetings', 'meeting_series_exceptions', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set. This patch contains no
-- CREATE POLICY / ALTER TABLE ... ENABLE ROW LEVEL SECURITY statement.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both lists identical to patch-meetings-recurring-phase2-
-- update-series-this-and-future.sql's own restated lists, plus the
-- single new value 'meeting_series_cancelled' appended.

SELECT column_name FROM information_schema.columns
WHERE table_name IN ('meeting_series', 'meetings') ORDER BY table_name, column_name;
-- Expect: identical column set to before this patch — no ALTER TABLE
-- ... ADD/DROP COLUMN statement anywhere in this patch.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (full dependency chain through patch-meetings-recurring- ─────────
-- ─── phase2-preserve-series-membership.sql, then this patch; ──────────
-- ─── hex-only UUID fixtures; SET ROLE authenticated + ──────────────────
-- ─── request.jwt.claim.sub per test) — summary for reference: ──────────
--
--   A/B) cancel_entire_series() on a fresh 6-occurrence active
--        series: all 6 occurrences return outcome='cancelled'; a
--        re-SELECT confirms all 6 meetings rows now have
--        status='cancelled', cancelled_by/cancelled_at set.
--   C) An occurrence with a linked, confirmed meeting_room_bookings
--      row: after the call, that booking's status is 'cancelled' too
--      (cancel_meeting()'s own inline booking-cancellation logic,
--      unmodified, reused as-is).
--   D) Meeting ids: the set of ids returned with outcome='cancelled'
--      is byte-for-byte the same set that existed before the call —
--      no INSERT/DELETE against meetings anywhere in this function.
--   E) Booking id: the SAME meeting_room_bookings.id from before the
--      call is re-queried afterward with status='cancelled' — no new
--      booking row created, the old one not deleted.
--   F) An occurrence already cancelled beforehand (plain
--      cancel_meeting() call, no exception row): returns
--      outcome='skipped_cancelled'; left untouched (status stays
--      'cancelled', cancelled_at/cancelled_by unchanged from the
--      original cancellation, not overwritten by this call).
--   G) An occurrence with end_at already in the past (test harness
--      backdates it directly): returns outcome='skipped_completed';
--      status remains 'scheduled', never touched.
--   H) An occurrence individually detached beforehand (plain
--      update_meeting() edit): returns outcome='skipped_detached';
--      status remains 'scheduled', completely untouched.
--   I) An occurrence "moved" beforehand (plain update_meeting()
--      time-only shift + create_series_exception(..., 'modified')):
--      returns outcome='skipped_detached' — the same convergence
--      documented throughout this module; its meeting_series_
--      exceptions row is confirmed unchanged (still references this
--      series' id) after the call.
--   J) An occurrence locked by its creator, with the cancellation
--      performed by a different, non-overriding org supervisor:
--      returns outcome='skipped_locked'; status remains 'scheduled',
--      is_locked remains TRUE.
--   K) Series status: re-SELECTed after the call, meeting_series.
--      status = 'cancelled' for the target series — confirmed set
--      unconditionally, including a second empirical case where
--      every occurrence in the series was already excluded (all
--      completed) and affected=0: the series status still
--      transitions to 'cancelled'.
--   L) Exactly one consolidated notification PER AFFECTED PARTICIPANT
--      (never one per occurrence): a call touching 4 eligible
--      occurrences (2 excluded by lifecycle categories), made by a
--      supervisor who is neither the series creator nor a participant,
--      against a series where the creator (auto-added as a
--      participant by create_recurring_meeting()) and one explicitly-
--      added participant are both distinct from the actor, produces
--      exactly 2 notification rows — one per distinct recipient, not
--      4, not 8 (occurrences x recipients) — confirming
--      SELECT DISTINCT mp.user_id ... WHERE mp.user_id <> v_actor
--      collapses correctly across occurrences regardless of how many
--      distinct participants end up in scope. Confirmed via a
--      superuser query (RLS otherwise hides these rows from the
--      acting caller, since notif_select is user_id = auth.uid() and
--      the actor here received no notification of their own action —
--      the same pre-existing, unrelated visibility gap already
--      documented for update_entire_series()/update_series_this_and_
--      future()).
--   M) Exactly one consolidated audit row: the same call produces
--      exactly 1 audit_logs row (action='meeting_series_cancelled',
--      record_type='meeting_series', record_id = the series id),
--      written unconditionally (also independently confirmed on the
--      affected=0 case from K).
--   N) Per-occurrence cancellation audits remain: alongside the 1
--      consolidated row from M, the 4 separate pre-existing
--      action='cancelled'/record_type='meeting' rows that
--      cancel_meeting() itself still wrote (one per actually-
--      cancelled occurrence) are confirmed present and untouched.
--   O) A same-organization plain staff member (not creator, not
--      supervisor-or-above): rejected with "Not authorized to manage
--      this meeting series"; confirmed zero meetings/meeting_series
--      rows changed and zero audit_logs/notifications rows written.
--   P) An unknown (nonexistent) series id: rejected with "Meeting
--      series not found".
--   Q) A series already cancelled (via a prior call to this same
--      function): a second call rejects with "This series has
--      already been cancelled" — confirmed this fires before any
--      per-occurrence work and before the authorization check is
--      even reached, tested with both an authorized and an
--      unauthorized caller against the same already-cancelled
--      series, both receiving the identical rejection.
--   R) update_entire_series(), called directly against the now-
--      cancelled series from Q: rejected with "This series has been
--      cancelled" — confirms the pre-existing, unmodified check in
--      update_entire_series() correctly reacts to the status this
--      new RPC actually sets.
--   S) update_series_this_and_future(), called directly against the
--      same cancelled series (from any of its still-scheduled/
--      excluded occurrences): rejected with "This series has been
--      cancelled" — same confirmation as R, for the sibling RPC.
--   T) Notification suppression: cancel_meeting() called directly
--      with p_suppress_notification := TRUE (outside this RPC) still
--      produces zero notifications, unchanged.
--   U) Idempotency: re-running patch-meetings-recurring-phase2-
--      cancel-entire-series.sql a second time against the same
--      project leaves overload_count at exactly 1, with no errors,
--      and re-running checks 1-4 above returns identical results.

-- ─── 6. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-cancel-entire-series.sql a
-- second time against the same project, then re-run checks 1–4 above
-- — all must return identical results. The two ALTER TABLE ... DROP/
-- ADD CONSTRAINT pairs and the single CREATE OR REPLACE FUNCTION are
-- each idempotent by construction.
