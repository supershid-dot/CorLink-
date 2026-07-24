-- ─── Validation: Recurring Meetings Phase 2 — Cancel This and Future ─
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-cancel-series-this-and-future.sql
-- has been applied there, to confirm the migration behaved as
-- designed. Every query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- cancel_series_this_and_future(p_meeting_id, p_cancellation_reason)
-- RETURNS TABLE(meeting_id, occurrence_date, outcome). No CHECK
-- constraint is touched — it reuses 'meeting_series_cancelled', added
-- by patch-meetings-recurring-phase2-cancel-entire-series.sql.

-- ─── V. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_series_this_and_future'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── SECURITY DEFINER with search_path pinned ───────────────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_series_this_and_future';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 'v'.

-- ─── Exact signature ─────────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'cancel_series_this_and_future';
-- Expect: args = 'p_meeting_id uuid, p_cancellation_reason text',
-- ret = 'TABLE(meeting_id uuid, occurrence_date date, outcome text)'.

-- ─── RLS and schema unchanged — no CHECK-constraint change at all ──
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meetings', 'meeting_series_exceptions', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set. This patch contains no
-- CREATE POLICY / ALTER TABLE ... ENABLE ROW LEVEL SECURITY, and no
-- ALTER TABLE ... DROP/ADD CONSTRAINT of any kind — the first patch
-- in this entire Phase 2 series with zero schema-adjacent statements.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both lists byte-for-byte identical to whatever patch-
-- meetings-recurring-phase2-cancel-entire-series.sql last set —
-- unchanged by this patch.

SELECT column_name FROM information_schema.columns
WHERE table_name IN ('meeting_series', 'meetings') ORDER BY table_name, column_name;
-- Expect: identical column set to before this patch.

-- ─── Functional test — empirically verified via local Postgres ─────
-- (full dependency chain through patch-meetings-recurring-phase2-
-- cancel-entire-series.sql, then this patch; hex-only UUID fixtures;
-- SET ROLE authenticated + request.jwt.claim.sub per test) — summary
-- for reference:
--
--   A) Cancel this and future from occurrence 3 of a 6-occurrence
--      active series: occurrences 1-2 report no row at all from this
--      call (never inspected — dated before the split) and remain on
--      the OLD series id, status unchanged ('scheduled'). Occurrences
--      3-6 all report outcome='cancelled'.
--   B) Cancel this and future AT the first occurrence of a series:
--      returns EXACTLY the same row set cancel_entire_series() itself
--      would return for that series (all occurrences outcome=
--      'cancelled', 0 new meeting_series rows created for the org).
--   C) New (split) series metadata, re-SELECTed after test A:
--      organization_id, created_by, recurrence_pattern,
--      interval_count, days_of_week, and every template_* field match
--      the SOURCE series exactly (verbatim clone — this function
--      takes no content-editing parameters); series_start_date equals
--      the split occurrence's own series_occurrence_date;
--      series_end_date equals the source series' pre-split
--      series_end_date.
--   D) Original series remains active: status = 'active' after the
--      call (re-SELECTed); series_end_date shrunk to
--      (split_date - 1); series_start_date/template_*/created_by all
--      unchanged from before the call.
--   E) New (split) series becomes cancelled: status = 'cancelled'
--      after the call — confirmed both in the normal case (test A,
--      affected=4) and independently in an all-excluded case (every
--      occurrence from the split date forward already completed):
--      the split series still ends up status='cancelled' even though
--      zero occurrences were actually cancellable.
--   F) Future eligible occurrences cancelled: re-SELECT of
--      occurrences 3-6 from test A shows status='cancelled',
--      cancelled_by/cancelled_at set, series_id = the NEW series id.
--   G) Past occurrences (1-2, dated before the split) unchanged:
--      status still 'scheduled', series_id still the ORIGINAL series
--      id, never inspected or touched by either pass.
--   H) Meeting ids preserved: the set of ids returned across all
--      outcomes in test A is byte-for-byte the same set that existed
--      on the original series before the call — no INSERT/DELETE
--      against meetings anywhere in this function.
--   I) Booking id preserved: an occurrence with a linked, confirmed
--      meeting_room_bookings row, included in the eligible split
--      range: after the call, the SAME booking id (re-queried by
--      meeting_id) exists with status='cancelled' — cancel_meeting()'s
--      own unmodified inline booking-cancellation logic, reused as-is
--      after the occurrence was repointed.
--   J) A detached occurrence (plain update_meeting() edit, on/after
--      the split date): returns outcome='skipped_detached'; re-SELECT
--      confirms series_id UNCHANGED (still the OLD series) and
--      status still 'scheduled' — never repointed, never cancelled.
--   K) A modified/moved occurrence (plain update_meeting() time-only
--      shift + create_series_exception(..., 'modified')): returns
--      outcome='skipped_detached' — the same convergence documented
--      throughout this module; its meeting_series_exceptions row
--      still references the OLD series id afterward, confirmed
--      unchanged.
--   L) A completed occurrence (backdated start_at/end_at, via a
--      superuser UPDATE bypassing RLS — meetings has no UPDATE policy
--      for ordinary roles, and both columns must move together to
--      satisfy meetings_range_check): returns outcome=
--      'skipped_completed'; series_id unchanged, status unchanged.
--   M) A locked, non-overridable occurrence (locked by its creator,
--      cancelled by a different, non-overriding org supervisor):
--      returns outcome='skipped_locked'; series_id unchanged, status
--      unchanged, is_locked still TRUE.
--   N) A same-organization plain staff member (not creator, not
--      supervisor-or-above): rejected with "Not authorized to manage
--      this meeting series"; confirmed zero meetings/meeting_series
--      rows changed and zero audit_logs/notifications rows written.
--   O) An unknown (nonexistent) meeting id: rejected with "Meeting
--      not found". A meeting that exists but has no series_id:
--      rejected with "This meeting is not part of a recurring
--      series".
--   P) A series already cancelled (via a prior cancel_entire_series()
--      or cancel_series_this_and_future() call): rejected with "This
--      series has already been cancelled" — confirmed this fires
--      before any new series row is created and before the
--      authorization check is even reached, tested with both an
--      authorized and an unauthorized caller against the same
--      cancelled series, both receiving the identical rejection.
--   Q) One consolidated notification per distinct affected
--      participant (never one per occurrence): a call touching 4
--      eligible occurrences with the series creator (auto-added as a
--      participant) and an explicitly-added participant both distinct
--      from a supervisor-actor produces exactly 2 notification rows
--      (type='meeting_series_cancelled', record_id = the NEW series
--      id) — not 4, not 8 — confirmed via a superuser query (RLS
--      otherwise hides these from the acting non-recipient caller,
--      the same pre-existing, unrelated visibility gap already
--      documented throughout this module).
--   R) Exactly one consolidated audit row: the same call produces
--      exactly 1 audit_logs row (action='meeting_series_cancelled',
--      record_type='meeting_series', record_id = the NEW series id),
--      written unconditionally (also independently confirmed on the
--      all-excluded, affected=0 case from E).
--   S) Per-occurrence cancellation audits remain: alongside the 1
--      consolidated row from R, the separate pre-existing
--      action='cancelled'/record_type='meeting' rows that
--      cancel_meeting() itself still wrote (one per actually-
--      cancelled occurrence) are confirmed present and untouched.
--   T) Notification suppression: cancel_meeting() called directly
--      with p_suppress_notification := TRUE (outside this RPC) still
--      produces zero notifications, unchanged.
--   U) Idempotency: re-running patch-meetings-recurring-phase2-
--      cancel-series-this-and-future.sql a second time against the
--      same project leaves overload_count at exactly 1, with no
--      errors, and re-running the structural checks above returns
--      identical results.
--
-- (Regression) cancel_entire_series(), called directly and via test
--   B's collapse path: unchanged behavior in both cases.
-- (Regression) update_entire_series() and update_series_this_and_
--   future(), re-tested directly after this patch against an
--   unrelated series: unchanged.
-- (Regression) create_series_exception(): re-tested directly after
--   this patch — still succeeds for an authorized caller on an unused
--   date, still rejects a duplicate date, unchanged.
-- (Regression) can_manage_series(): re-tested directly after this
--   patch — still returns TRUE for the series creator, FALSE for an
--   unrelated same-org staff member, unchanged.
-- (Regression) No RLS policy anywhere changed; meeting_series/
--   meetings column sets unchanged; no CHECK constraint touched at
--   all by this patch — the only statement in the entire file besides
--   the function definition is the CREATE OR REPLACE FUNCTION itself.
