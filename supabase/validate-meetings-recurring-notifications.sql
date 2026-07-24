-- ─── Validation: Recurring room-approval notification batching ──
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-notifications.sql has been applied there,
-- to confirm the migration behaved as designed. Every query below is
-- a SELECT — nothing here writes data.
--
-- Corresponds to docs/25-recurring-meetings-phase1-design-decisions.md
-- §3 (the approved decision) and the follow-up implementation task
-- that authorized this patch.

-- ─── 1. Exactly one overload of each modified function exists ──
-- Confirms the DROP FUNCTION statements did their job — no ambiguous
-- old+new overload pair left behind.
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('submit_booking_request', 'assign_room_booking', 'create_recurring_meeting')
GROUP BY p.proname
ORDER BY p.proname;
-- Expect: exactly 1 row per function, each count = 1.

-- ─── 2. New parameter present, SECURITY DEFINER + search_path pinned ─
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('submit_booking_request', 'assign_room_booking', 'create_recurring_meeting')
ORDER BY p.proname;
-- Expect: submit_booking_request and assign_room_booking both list
-- 'p_suppress_notification boolean DEFAULT false' as their final
-- argument; create_recurring_meeting's argument list is unchanged
-- from patch-meetings-recurring.sql (no new parameter — signature
-- untouched, per requirement 9). All three: prosecdef = true,
-- proconfig containing 'search_path=public, pg_temp'.

-- ─── 3. RLS unchanged — no new policy, no direct-write policy ──
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_room_bookings', 'notifications', 'audit_logs')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set (this patch adds no RLS
-- policy of its own — every write in this feature goes through the
-- three RPCs above, unchanged from before).

-- ─── 4. notifications.type CHECK extended correctly (full ──────
-- ─── accumulated list, not a bare addition) ────────────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: includes 'recurring_booking_submitted' alongside every
-- pre-existing value (including 'meeting_series_created').

-- ─── 5. audit_logs CHECK constraints UNCHANGED — this feature ──
-- ─── introduces no new audit action or record_type ─────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_record_type_check';
-- Expect: both byte-for-byte identical to their state after
-- patch-meetings-recurring.sql — no new value in either list.

-- ─── 6. Functional test — empirically verified via local ───────
-- ─── Postgres (see session record) — summary for reference: ───────
--   a) A standalone (non-recurring) booking request via
--      submit_booking_request(), called with no p_suppress_notification
--      argument (matching every existing frontend call site), still
--      produces exactly one 'booking_submitted' notification per room
--      manager, identical to before this patch (requirement 1).
--   b) A recurring series requiring room approval (creator is not a
--      manager of the target room) produces exactly ONE
--      'recurring_booking_submitted' notification per room manager,
--      regardless of occurrence count — verified with a 4-occurrence
--      and a 12-occurrence series, both producing exactly 1
--      notification per manager, not N.
--   c) With two distinct room managers on the same room, each
--      receives their own single notification (2 total, not 1 shared
--      or 4 duplicated).
--   d) Two separate recurring series against two different rooms (in
--      the same call sequence) each produce their own single,
--      correctly-room-scoped notification to that room's own
--      manager(s) — no cross-room bleed.
--   e) The consolidated notification's message contains the series
--      title and id, the room name, the correct occurrence count, and
--      the correct first/last occurrence dates (spot-checked against
--      the actual generated occurrence rows).
--   f) A room-booked series created by a room MANAGER (auto-confirm
--      path, create_room_booking()) produces ZERO notifications of
--      any kind — identical to today's single-meeting behavior; the
--      consolidated notification only fires on the approval-required
--      path.
--   g) Every individual meeting_room_bookings row still exists, one
--      per occurrence, with status 'pending' (approval-required
--      series) or 'confirmed' (manager-created series) exactly as
--      before this patch (requirement 4).
--   h) Every individual booking's audit_logs 'submitted'/
--      'meeting_room_booking' row still exists, one per occurrence,
--      with the same count as before this patch — confirmed via
--      before/after row-count comparison against an identical series
--      created pre-patch (requirement 5).
--   i) Approving one occurrence's booking (approve_booking) and
--      rejecting a different occurrence's booking (reject_booking)
--      within the same series both succeed independently; every
--      other occurrence's booking status is unaffected by either
--      action (requirements 6/7) — their own existing
--      'booking_approved'/'booking_rejected' notifications and audit
--      rows are unaffected by this patch, still one per action.
--   j) Room-booking conflict on one occurrence still rolls back the
--      ENTIRE series transaction (zero meetings, zero series, zero
--      bookings, zero notifications of any kind persisted) — the new
--      consolidated-notification INSERT is itself inside the same
--      transaction as everything else, so it is never left partially
--      applied either.
--   k) Unauthenticated/anon callers of all three modified RPCs are
--      rejected exactly as before ("requires an authenticated
--      caller").
--   l) Direct INSERT/UPDATE/DELETE against meeting_room_bookings and
--      notifications remains rejected by RLS — this patch adds no new
--      write policy to either table.
--   m) Existing booking ids are never regenerated or altered by this
--      patch — a booking created before this patch was applied
--      remains addressable by the same id after (requirement 8);
--      confirmed by re-running the idempotent patch a second time and
--      diffing meeting_room_bookings.id values before/after.

-- ─── 7. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-notifications.sql a second time
-- against the same project, then re-run checks 1–5 above — all must
-- return identical results, and no existing meeting_room_bookings,
-- notifications, or audit_logs row is touched (the patch contains no
-- seed/UPDATE statement against existing rows, only DROP+CREATE
-- FUNCTION and one CHECK-constraint restatement).
