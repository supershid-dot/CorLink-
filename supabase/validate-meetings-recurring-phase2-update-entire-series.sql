-- ─── Validation: Recurring Meetings Phase 2 — Update Entire Series ─
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-update-entire-series.sql has been
-- applied there, to confirm the migration behaved as designed. Every
-- query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- update_entire_series(p_series_id, p_title, p_description,
-- p_meeting_type, p_visibility, p_start_time, p_end_time, p_timezone,
-- p_location_mode, p_external_location, p_virtual_link) RETURNS
-- TABLE(meeting_id, occurrence_date, outcome), plus two CHECK-
-- constraint restatements adding 'meeting_series_updated'. No other
-- recurring-series Phase 2 RPC (update_series_this_and_future,
-- cancel_entire_series, cancel_series_this_and_future) or workflow
-- (skip occurrence, moved occurrence) is implemented by this patch or
-- validated here.

-- ─── 1. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_entire_series'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── 2. SECURITY DEFINER with search_path pinned ────────────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_entire_series';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 'v' (VOLATILE — this
-- function writes to meetings/audit_logs/notifications via
-- update_meeting() and its own INSERTs).

-- ─── 3. Exact signature ──────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_entire_series';
-- Expect: args = 'p_series_id uuid, p_title text, p_description text,
-- p_meeting_type text, p_visibility text, p_start_time time without
-- time zone, p_end_time time without time zone, p_timezone text,
-- p_location_mode text, p_external_location text, p_virtual_link
-- text', ret = 'TABLE(meeting_id uuid, occurrence_date date, outcome
-- text)'.

-- ─── 4. RLS and schema unchanged beyond the two CHECK restatements ──
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meetings', 'meeting_series_exceptions')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set. This patch contains no
-- CREATE POLICY / ALTER TABLE ... ENABLE ROW LEVEL SECURITY statement.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both lists identical to their pre-patch content plus the
-- single new value 'meeting_series_updated' appended. No other value
-- added or removed, confirming the restatement was transcribed from a
-- live, verified query rather than reconstructed from memory.

SELECT column_name FROM information_schema.columns
WHERE table_name IN ('meeting_series', 'meetings') ORDER BY table_name, column_name;
-- Expect: identical column set to before this patch — no ALTER TABLE
-- ... ADD/DROP COLUMN statement anywhere in this patch.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (schema.sql + rls.sql + security-functions.sql, then the full ────
-- ─── rooms/meetings patch chain through patch-meetings-recurring- ─────
-- ─── phase2-series-exceptions.sql, then this patch; hex-only UUID ─────
-- ─── fixtures; SET ROLE authenticated + request.jwt.claim.sub per ─────
-- ─── test) — summary for reference: ────────────────────────────────────
--
--   A) Series creator updates title only on a 4-occurrence future
--      series: all 4 occurrences return outcome='updated'; a re-SELECT
--      of all 4 meetings rows shows the new title; start_at/end_at/
--      location fields on all 4 unchanged. Exactly one
--      'meeting_series_updated' notification per distinct participant
--      across the 4 occurrences (not 4 separate notifications).
--   B) Location only (external_location + location_mode='external'):
--      all future/attached/unlocked occurrences updated; title/time
--      unchanged on each; one consolidated notification (location
--      change is inside update_meeting()'s own meaningful-change set).
--   C) Description only: all eligible occurrences show outcome=
--      'updated' and the new description on re-SELECT — but ZERO
--      notifications rows are produced (description is not part of
--      update_meeting()'s own per-occurrence notification-firing
--      condition, and this RPC's own v_meaningful_change mirrors that
--      exactly).
--   D) Multiple fields at once (title + start_time + end_time +
--      timezone): each occurrence's start_at/end_at recomputed as its
--      own fixed series_occurrence_date combined with the new time-of-
--      day and zone — occurrence dates themselves unchanged, only the
--      time-of-day portion shifts identically across all occurrences.
--      One consolidated notification.
--   E) One occurrence individually detached beforehand via a plain
--      call to update_meeting() (e.g. editing only that occurrence's
--      own title directly, not through this RPC): that occurrence
--      returns outcome='skipped_detached' and its title is NOT
--      touched by a subsequent update_entire_series() title change;
--      the other 3 occurrences update normally.
--   F) A different occurrence skipped beforehand via cancel_meeting()
--      + create_series_exception(..., 'skipped') (the locked skip-
--      semantics route): returns outcome='skipped_cancelled'; a
--      subsequent update_entire_series() call leaves its title/status
--      untouched (still 'cancelled').
--   G) A third occurrence "moved" beforehand via a plain
--      update_meeting() time-only shift + create_series_exception(...,
--      'modified') (the locked modified-occurrence route): returns
--      outcome='skipped_detached' — confirmed the SAME outcome
--      category as test E, empirically verifying the documented
--      convergence (design decision 4) rather than a distinct
--      "skipped_modified" category that doesn't exist. Its shifted
--      time is confirmed unchanged by the subsequent series-wide call.
--   H) A same-organization plain staff member (not creator, not
--      supervisor-or-above): rejected with "Not authorized to manage
--      this meeting series". Confirmed zero meetings rows changed and
--      zero audit_logs/notifications rows written.
--   I) An unknown (nonexistent) series id: rejected with "Meeting
--      series not found".
--   J) A series with status='cancelled' (set directly via UPDATE for
--      test purposes, since no RPC sets this yet): rejected with
--      "This series has been cancelled" — confirmed this check fires
--      BEFORE the authorization check would even be reached (tested
--      with both an authorized and an unauthorized caller against the
--      same cancelled series; both receive the identical cancelled-
--      series rejection, not the authorization one, confirming the
--      documented check-order).
--   K) Across test A's single call: exactly one row with
--      type='meeting_series_updated' per distinct notified participant
--      — not one row per occurrence (4 occurrences, but each shared
--      participant receives exactly 1 notification row, confirmed via
--      SELECT DISTINCT user_id count matching the notifications row
--      count exactly).
--   L) Across test A's single call: exactly one audit_logs row with
--      action='meeting_series_updated', record_type='meeting_series',
--      record_id=the series id — not one per occurrence (confirmed
--      count=1 immediately after the call, alongside the 4 separate
--      pre-existing per-occurrence action='edited'/record_type=
--      'meeting' rows that update_meeting() itself still wrote, one
--      per updated occurrence, left completely intact).
--   M) A genuinely completed occurrence: with the test session
--      temporarily RESET to a role permitted to write meetings
--      directly (meetings has no UPDATE policy for ordinary
--      authenticated callers — a write attempted under that role
--      silently matches zero rows rather than erroring), both
--      start_at AND end_at were moved into the past together
--      (preserving start_at < end_at, required by
--      meetings_range_check — moving end_at alone would violate it),
--      and the row was re-SELECTed to confirm the backdate actually
--      took effect before the session was restored to the
--      authenticated test role. update_entire_series() then reports
--      that occurrence as outcome='skipped_completed'; a re-SELECT
--      confirms its title/status/start_at/end_at are byte-for-byte
--      unchanged from the backdated values — the RPC's own
--      `end_at < now()` check, unmodified since this patch first
--      shipped. (This scenario was originally absent from this
--      patch's own validation — its task scope never required a
--      completed-occurrence case — and was added during the Phase 2
--      final integration review to close that gap; see
--      docs/28-recurring-meetings-phase2-implementation.md §15 for the full
--      historical note.)
--   (Regression) update_meeting() called directly (outside this RPC)
--      on an ordinary, non-series meeting: behaves identically to
--      before this patch — title/time/location edits, notification
--      firing, and series_detached bookkeeping (N/A, series_id NULL)
--      all unchanged.
--   (Regression) Notification suppression (calling update_meeting()/
--      cancel_meeting()/reschedule_booking() directly with
--      p_suppress_notification := TRUE): still produces zero
--      notifications, exactly as before this patch.
--   (Regression) create_series_exception(): re-tested directly after
--      this patch — still succeeds for an authorized caller on an
--      unused date, still rejects a duplicate date, unchanged.
--   (Regression) can_manage_series(): re-tested directly after this
--      patch — still returns TRUE for the series creator, FALSE for
--      an unrelated same-org staff member, unchanged.
--   (Regression) No RLS policy anywhere changed (checks 4 above);
--      meeting_series/meetings column sets unchanged; the only schema-
--      adjacent change in this entire patch is the two CHECK-
--      constraint restatements, each strictly additive (one new value
--      appended, nothing removed or reordered incorrectly).

-- ─── 6. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-update-entire-series.sql a
-- second time against the same project, then re-run checks 1–4 above
-- — all must return identical results. The two ALTER TABLE ... DROP/
-- ADD CONSTRAINT pairs and the single CREATE OR REPLACE FUNCTION are
-- each idempotent by construction.
