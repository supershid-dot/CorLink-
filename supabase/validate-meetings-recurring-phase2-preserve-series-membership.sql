-- ─── Validation: Preserve Series Membership During Bulk Updates ────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-preserve-series-membership.sql has
-- been applied there, to confirm the fix behaved as designed. Every
-- query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch redefines update_meeting() (adds one
-- trailing parameter, p_preserve_series_membership BOOLEAN DEFAULT
-- FALSE, and makes the series_detached bookkeeping conditional on
-- it), update_entire_series(), and update_series_this_and_future()
-- (both unchanged externally — only their internal update_meeting()
-- call now also passes p_preserve_series_membership := TRUE). No new
-- RPC, no CHECK-constraint change, no schema change.

-- ─── N. Exactly one live overload per recreated function ────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('update_meeting', 'update_entire_series', 'update_series_this_and_future')
GROUP BY p.proname ORDER BY p.proname;
-- Expect: 3 rows, each count = 1.

SELECT pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'update_meeting';
-- Expect: ..., p_suppress_notification boolean, p_preserve_series_membership boolean'
-- (14 parameters total, p_preserve_series_membership last).

SELECT p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('update_meeting', 'update_entire_series', 'update_series_this_and_future');
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 'v' on all three.

-- ─── 4. Schema/RLS unchanged ─────────────────────────────────────────
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meetings', 'meeting_series_exceptions', 'meeting_room_bookings')
ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set — no policy statement
-- anywhere in this patch.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: both identical to what patch-meetings-recurring-phase2-
-- update-series-this-and-future.sql last set — this patch touches
-- neither constraint.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (full dependency chain through patch-meetings-recurring- ─────────
-- ─── phase2-update-series-this-and-future.sql, then this patch; ───────
-- ─── hex-only UUID fixtures; SET ROLE authenticated + ──────────────────
-- ─── request.jwt.claim.sub per test) — summary for reference: ──────────
--
--   A) A direct update_meeting() call on a series-linked occurrence
--      with p_preserve_series_membership omitted entirely (legacy call
--      shape, no new argument supplied): series_detached becomes
--      TRUE, exactly as before this patch.
--   B) The same, with p_preserve_series_membership := FALSE passed
--      explicitly: series_detached becomes TRUE — identical outcome
--      to the default, confirming FALSE truly means "unchanged
--      legacy behavior" rather than some other semantics.
--   C) update_entire_series() on a fresh 6-occurrence series: all 6
--      occurrences return outcome='updated'; re-SELECT confirms all 6
--      have series_detached = FALSE afterward (not TRUE) — the
--      specific defect this patch fixes.
--   D) The SAME series, update_entire_series() called a SECOND time
--      with a different title: all 6 occurrences again return
--      outcome='updated' (not skipped_detached), and the new title is
--      applied — confirming repeated bulk edits on the same series
--      now work. Before this patch, this second call returned 100%
--      skipped_detached and changed nothing; reproduced and confirmed
--      fixed.
--   E) update_series_this_and_future() splitting a fresh 6-occurrence
--      series in the middle: repointed + updated occurrences land on
--      the new series with series_detached = FALSE, confirmed via
--      re-SELECT.
--   F) The newly split-off series from (E), update_series_this_and_
--      future() called AGAIN on one of its own occurrences (a further
--      split, or effectively "update the tail again"): eligible
--      occurrences return outcome='updated' (not skipped_detached).
--      Before this patch this returned 100% skipped_detached;
--      reproduced and confirmed fixed. Also independently confirmed:
--      calling update_entire_series() directly a second time on an
--      already-split-off new series succeeds identically.
--   G) A genuinely, individually detached occurrence (plain
--      update_meeting() call with the new parameter omitted, i.e. the
--      legacy path from scenario A): a subsequent update_entire_
--      series() call on that series still reports it as
--      outcome='skipped_detached' and leaves it untouched — bulk
--      operations still correctly respect a real individual override;
--      this patch narrows the false-positive case, it does not widen
--      what counts as "still eligible."
--   H) A "modified" (moved) occurrence (update_meeting() time-only
--      shift with the new parameter omitted, then create_series_
--      exception(..., 'modified')): a subsequent bulk call still
--      reports outcome='skipped_detached' and leaves both the
--      occurrence and its exception row untouched — unchanged from
--      pre-fix behavior.
--   I) Meeting ids: re-verified unchanged across a double bulk-edit
--      sequence (C then D) — same 6 ids throughout, no INSERT/DELETE
--      against meetings.
--   J) Booking id: a room-booked occurrence included in a double
--      bulk-edit sequence keeps the same meeting_room_bookings.id
--      across both calls, with start/end reflecting the latest edit.
--   K) update_meeting() notification suppression: re-tested directly
--      with p_suppress_notification := TRUE (new parameter omitted)
--      — still produces zero notifications, unchanged.
--   L) update_meeting() called with neither new-era parameter
--      supplied at all (p_meeting_id and one or two edited fields
--      only, exactly as the oldest call sites in this codebase do) —
--      succeeds identically to before this patch; both new trailing
--      defaults (p_suppress_notification := FALSE, p_preserve_series_
--      membership := FALSE) apply silently with no call-site changes
--      required anywhere in the codebase.
--   M) Authorization (can_manage_meeting()/can_manage_series()),
--      lock checks (is_meeting_lock_overridable()), module-active
--      checks: all re-tested directly, unchanged. A conflicting/
--      invalid edit (blank title, end_at <= start_at) still raises
--      the identical exception message and rolls back the same as
--      before.
--   N) A genuinely completed occurrence, with p_preserve_series_
--      membership in play: with the test session temporarily RESET to
--      a role permitted to write meetings directly (meetings has no
--      UPDATE policy for ordinary authenticated callers), both
--      start_at AND end_at were moved into the past together
--      (preserving start_at < end_at, required by
--      meetings_range_check), and the row was re-SELECTed to confirm
--      the backdate actually took effect before the session was
--      restored to the authenticated test role. A subsequent
--      update_entire_series() call (which now passes
--      p_preserve_series_membership := TRUE internally) still reports
--      that occurrence as outcome='skipped_completed' and leaves it
--      completely untouched — confirming the completed-occurrence
--      exclusion and the preserve-membership fix are independent
--      checks that do not interact. (This scenario was originally
--      absent from this patch's own validation and was added during
--      the Phase 2 final integration review; see
--      docs/28-recurring-meetings-phase2-implementation.md §15.)
--   O) Exactly one live overload for each of update_meeting(),
--      update_entire_series(), update_series_this_and_future() —
--      confirmed via the structural query above; the old 13-parameter
--      update_meeting() signature no longer resolves at all.
--   P) Idempotency: re-running patch-meetings-recurring-phase2-
--      preserve-series-membership.sql a second time against the same
--      project leaves overload_count at exactly 1 for all three
--      functions, with no errors.

-- ─── Parity diff notes (see patch header design decisions) ──────────
-- update_meeting(): the ONLY line that differs from the version
-- shipped in patch-meetings-recurring-phase2-notification-
-- suppression.sql is the series_detached CASE expression (AND NOT
-- p_preserve_series_membership appended) plus the new trailing
-- parameter declaration itself. Every other line — validation order,
-- exception messages, the reschedule_booking() call, the audit
-- INSERT, both notification branches — is byte-for-byte identical.
--
-- update_entire_series(): identical to the version shipped in
-- patch-meetings-recurring-phase2-update-entire-series.sql except one
-- added named argument, p_preserve_series_membership := TRUE, on its
-- existing PERFORM update_meeting(...) call. Signature, RETURNS
-- TABLE shape, all checks, the classification loop, the time-of-day
-- formula, the audit/notification INSERTs are byte-for-byte
-- identical.
--
-- update_series_this_and_future(): identical to the version shipped
-- in patch-meetings-recurring-phase2-update-series-this-and-
-- future.sql except the same one added named argument on its own
-- pass-2 PERFORM update_meeting(...) call. Everything else — the
-- first-occurrence collapse, the two-pass split, the new-series
-- INSERT, the old-series series_end_date shrink, the audit/
-- notification INSERTs — is byte-for-byte identical.
