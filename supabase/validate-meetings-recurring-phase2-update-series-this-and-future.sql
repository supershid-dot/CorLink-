-- ─── Validation: Recurring Meetings Phase 2 — Update This and Future ─
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-update-series-this-and-future.sql
-- has been applied there, to confirm the migration behaved as
-- designed. Every query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- update_series_this_and_future(p_meeting_id, p_title, p_description,
-- p_meeting_type, p_visibility, p_start_time, p_end_time, p_timezone,
-- p_location_mode, p_external_location, p_virtual_link) RETURNS
-- TABLE(meeting_id, occurrence_date, outcome), plus two CHECK-
-- constraint restatements adding 'meeting_series_split'.
-- cancel_entire_series() and cancel_series_this_and_future() are not
-- implemented here.

-- ─── 1. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_series_this_and_future'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── 2. SECURITY DEFINER with search_path pinned ────────────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_series_this_and_future';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 'v'.

-- ─── 3. Exact signature ──────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_series_this_and_future';
-- Expect: args = 'p_meeting_id uuid, p_title text, p_description
-- text, p_meeting_type text, p_visibility text, p_start_time time
-- without time zone, p_end_time time without time zone, p_timezone
-- text, p_location_mode text, p_external_location text,
-- p_virtual_link text', ret = 'TABLE(meeting_id uuid, occurrence_date
-- date, outcome text)'.

-- ─── 4. RLS and schema unchanged beyond the two CHECK restatements ──
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meetings', 'meeting_series_exceptions', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set. This patch contains no
-- CREATE POLICY / ALTER TABLE ... ENABLE ROW LEVEL SECURITY statement.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both lists identical to patch-meetings-recurring-phase2-
-- update-entire-series.sql's own restated lists, plus the single new
-- value 'meeting_series_split' appended.

SELECT column_name FROM information_schema.columns
WHERE table_name IN ('meeting_series', 'meetings') ORDER BY table_name, column_name;
-- Expect: identical column set to before this patch — no ALTER TABLE
-- ... ADD/DROP COLUMN statement anywhere in this patch.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (full dependency chain through patch-meetings-recurring- ─────────
-- ─── phase2-update-entire-series.sql, then this patch; hex-only ───────
-- ─── UUID fixtures; SET ROLE authenticated + request.jwt.claim.sub ────
-- ─── per test) — summary for reference: ────────────────────────────────
--
--   A) Split in the middle of a 6-occurrence weekly series (occurrence
--      3 of 6 as the split point): occurrences 1-2 report no row at
--      all from this call (never inspected — dated before the split)
--      and remain on the OLD series id, series_id unchanged.
--      Occurrences 3-6 all report outcome='updated', and a re-SELECT
--      confirms all four now have series_id = a brand-new series id
--      (different from the original), with series_occurrence_date
--      unchanged on every one of them and the new title applied.
--   B) Split AT the first occurrence of a series: returns EXACTLY the
--      same row set update_entire_series() itself would return for
--      that series (all occurrences outcome='updated', 0 new series
--      rows created — meeting_series row count for the org unchanged
--      before/after). Confirms the collapse shortcut, not a
--      degenerate 1-row-remaining split.
--   C) An occurrence dated on/after the split point that was
--      individually detached beforehand (plain update_meeting() title
--      edit, not through any bulk RPC): returns
--      outcome='skipped_detached'; re-SELECT confirms series_id
--      UNCHANGED (still the OLD series) and series_detached still
--      TRUE — never repointed.
--   D) An occurrence "moved" beforehand (plain update_meeting()
--      time-only shift + create_series_exception(..., 'modified')):
--      returns outcome='skipped_detached' — same convergence as
--      update_entire_series()'s own scenario G. Its
--      meeting_series_exceptions row still references the OLD series
--      id afterward (confirmed via re-SELECT), since the occurrence
--      itself was never repointed.
--   E) An occurrence skipped beforehand (cancel_meeting() +
--      create_series_exception(..., 'skipped')): returns
--      outcome='skipped_cancelled'; its meeting_series_exceptions row
--      still references the OLD series id afterward, confirmed
--      unchanged.
--   F) An occurrence locked by its creator, with the split performed
--      by a different, non-overriding org supervisor: returns
--      outcome='skipped_locked'; re-SELECT confirms series_id
--      unchanged (still OLD series) and is_locked still TRUE.
--   G) An occurrence with end_at already in the past (no legitimate
--      RPC path produces this — a series occurrence only becomes
--      genuinely completed through the passage of time — so the test
--      session was temporarily RESET to a role permitted to write
--      meetings directly: meetings has no UPDATE policy for ordinary
--      authenticated callers, so a write attempted under that role
--      would silently match zero rows rather than error. Both
--      start_at AND end_at were moved into the past together,
--      preserving start_at < end_at as meetings_range_check requires
--      — moving end_at alone would violate it — and the row was
--      re-SELECTed to confirm the backdate actually took effect
--      before the session was restored to the authenticated test
--      role): returns outcome='skipped_completed'; series_id
--      unchanged, and a re-SELECT confirms the occurrence is
--      otherwise untouched. (An earlier draft of this fixture ran the
--      backdating UPDATE under the authenticated role and moved only
--      end_at, so it silently affected zero rows — the original call
--      then saw a still-future occurrence and never genuinely
--      exercised this outcome. Corrected during the Phase 2 final
--      integration review; see docs/28-recurring-meetings-phase2-implementation.md
--      §15.)
--   H) A plain cancel_meeting()'d occurrence (status='cancelled', no
--      exception row): returns outcome='skipped_cancelled'; series_id
--      unchanged, status still 'cancelled'.
--   I) New series metadata, re-SELECTed after test A: organization_id
--      and created_by match the SOURCE series exactly;
--      recurrence_pattern/interval_count/days_of_week match the
--      source series exactly; series_start_date equals the split
--      occurrence's own series_occurrence_date; series_end_date
--      equals the source series' (pre-split) series_end_date;
--      template_title equals the new title passed to the call;
--      status='active'.
--   J) Old series metadata, re-SELECTed after test A: series_end_date
--      equals (split_date - 1); series_start_date, template_*,
--      recurrence_pattern, created_by all UNCHANGED from before the
--      call; status still 'active'.
--   K) Meeting ids preserved: the set of meeting ids returned with
--      outcome='updated' in test A is byte-for-byte the same set of
--      ids that existed (on the old series) before the call — no new
--      meetings row was inserted, no existing one was deleted
--      (confirmed via COUNT(*) FROM meetings for the series' original
--      6 occurrence ids, before and after, unchanged at 6, split only
--      by which series_id each now carries).
--   L) Booking ids preserved: an occurrence with a linked, confirmed
--      meeting_room_bookings row, included in the eligible split
--      range with a time-of-day edit requested: after the call, the
--      SAME booking id (re-queried by meeting_id) still exists with
--      its start/end shifted to match the new time — no new booking
--      row was created, no old one was cancelled or deleted.
--   M) One consolidated notification: test A's single call, touching
--      4 occurrences with a shared participant across all of them,
--      produces exactly 1 notification row
--      (type='meeting_series_split', record_id = the NEW series id),
--      not 4.
--   N) One consolidated audit row: test A's single call produces
--      exactly 1 audit_logs row (action='meeting_series_split',
--      record_type='meeting_series', record_id = the NEW series id),
--      alongside the 4 separate pre-existing per-occurrence
--      action='edited' rows update_meeting() itself still wrote (left
--      intact, one per updated occurrence).
--   O) A same-organization plain staff member (not creator, not
--      supervisor-or-above) calling on any occurrence of the series:
--      rejected with "Not authorized to manage this meeting series";
--      confirmed zero meetings/meeting_series rows changed and zero
--      audit_logs/notifications rows written.
--   P) A series with status='cancelled' (set directly via UPDATE for
--      test purposes): rejected with "This series has been
--      cancelled" — confirmed this fires before any new series row
--      is created and before the authorization check, tested with
--      both an authorized and an unauthorized caller against the same
--      cancelled series, both receiving the identical cancelled-
--      series rejection.
--   (Regression) update_entire_series(), called directly and via
--      test B's collapse path: unchanged behavior in both cases.
--   (Regression) Notification suppression: still produces zero
--      notifications when p_suppress_notification := TRUE is passed
--      directly to update_meeting()/cancel_meeting()/
--      reschedule_booking().
--   (Regression) create_series_exception(): re-tested directly after
--      this patch — still succeeds for an authorized caller on an
--      unused date, still rejects a duplicate date, unchanged.
--   (Regression) can_manage_series(): re-tested directly after this
--      patch — still returns TRUE for the series creator, FALSE for
--      an unrelated same-org staff member, unchanged.
--   (Regression) No RLS policy anywhere changed (check 4 above);
--      meeting_series/meetings column sets unchanged; the only
--      schema-adjacent change in this entire patch is the two CHECK-
--      constraint restatements, each strictly additive.

-- ─── 6. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-update-series-this-and-
-- future.sql a second time against the same project, then re-run
-- checks 1-4 above — all must return identical results.
