-- ============================================================
-- CorLink — Recurring Meetings Phase 2: "Cancel This and Future" RPC
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- cancel_series_this_and_future(p_meeting_id UUID, p_cancellation_
-- reason TEXT) RETURNS TABLE (meeting_id UUID, occurrence_date DATE,
-- outcome TEXT).
--
-- Nothing else changes. No other RPC is implemented here. No
-- frontend, no documentation. No CHECK constraint is touched — this
-- function reuses the 'meeting_series_cancelled' action/notification-
-- type value cancel_entire_series() already added
-- (patch-meetings-recurring-phase2-cancel-entire-series.sql); nothing
-- new needs to be recorded that value doesn't already cover.
--
-- Requires patch-meetings-recurring.sql (meeting_series.status),
-- patch-meetings-recurring-phase2-notification-suppression.sql
-- (cancel_meeting()'s p_suppress_notification parameter), patch-
-- meetings-recurring-phase2-series-auth.sql (can_manage_series()),
-- patch-meetings-recurring-phase2-update-series-this-and-future.sql
-- (the split-series architecture this function's genuine-split branch
-- follows), and patch-meetings-recurring-phase2-cancel-entire-
-- series.sql (cancel_entire_series(), called directly for the first-
-- occurrence collapse case, and the 'meeting_series_cancelled' CHECK
-- value it already added) already applied.
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. The split point is identified by p_meeting_id, for the identical
--    reason documented in update_series_this_and_future()'s own
--    design decision 1: it matches how the action is actually
--    initiated (from a specific occurrence's own UI, which already
--    has a concrete meeting id in hand) and avoids trusting the
--    caller to correctly compute/pass a matching date. The series id
--    and split date are both derived server-side:
--    v_series_id := meetings.series_id,
--    v_split_date := meetings.series_occurrence_date.
-- 2. Check order mirrors update_series_this_and_future() exactly:
--    authenticated caller -> meeting found -> meeting belongs to a
--    series -> series found -> series not already cancelled ->
--    authorized -> module active -> split-point determination. The
--    task's own architecture list separates "verify the occurrence
--    belongs to an active series" (structural: meeting/series
--    existence and linkage) from "reject cancelled series" (a status
--    check on the record already found) — both are checked, in that
--    order, before authorization, for the same reason update_series_
--    this_and_future() and cancel_entire_series() already established:
--    whether a record can be acted on at all is a property of the
--    record, independent of who is asking.
-- 3. First-occurrence collapse (locked architecture requirement,
--    identical to update_series_this_and_future()'s own design
--    decision 2): if no occurrence in the series has a series_
--    occurrence_date earlier than the split occurrence's own date,
--    "cancel this and future" is definitionally identical to "cancel
--    the entire series" — nothing would be left behind as still-
--    active, so splitting into two series rows would be pure overhead
--    with no observable difference. This function detects that case
--    and short-circuits directly to
--    RETURN QUERY SELECT * FROM cancel_entire_series(v_series.id,
--    p_cancellation_reason), passing the SAME series id through
--    unchanged — no new series is created, and cancel_entire_series()'s
--    own single audit row and single notification (record_id = the
--    original series) are the only ones produced for this call. This
--    is the only call site in this function that invokes cancel_
--    entire_series() — see design decision 9 for why a genuine split
--    does NOT also delegate to it for the per-occurrence work.
-- 4. Two-pass split algorithm for a genuine split, identical in shape
--    to update_series_this_and_future()'s own: occurrences with
--    series_occurrence_date >= the split date are classified using
--    the exact same four categories used throughout this module
--    (skipped_cancelled, skipped_detached, skipped_completed,
--    skipped_locked). Pass 1 repoints ONLY the eligible occurrences'
--    own meetings.series_id to the new series — nothing else about
--    those rows changes in this pass, and lifecycle-excluded
--    occurrences are never repointed at all: they stay exactly where
--    they are, attached to the OLD (still-active) series, in whatever
--    state they were already in. Pass 2 then cancels — via
--    cancel_meeting() — only the occurrences pass 1 actually
--    repointed (selected via WHERE series_id = v_new_series_id, which
--    after pass 1 is exactly and only that set). Occurrences dated
--    before the split date are never inspected, classified, or
--    touched by either pass, regardless of their own lifecycle state.
-- 5. Unlike update_series_this_and_future()'s tentative-series
--    pattern (which deletes an empty split rather than leaving a
--    pointless edited series behind), this function always keeps the
--    new series and always marks it cancelled, even when pass 1
--    repoints zero occurrences (every occurrence from the split date
--    forward was already lifecycle-excluded). This is a deliberate
--    difference, not an oversight: the architecture requirement here
--    is unconditional ("mark the split series cancelled"), mirroring
--    cancel_entire_series()'s own unconditional status-update
--    requirement — cancelling the "this and future" portion is this
--    call's actual, primary effect, not a byproduct of successfully
--    cancelling at least one occurrence. An empty, permanently-
--    cancelled split series still correctly and traceably records
--    "as of this call, everything from this occurrence forward was
--    cancelled" even when everything in that range happened to
--    already be excluded for an unrelated reason — and, just as
--    important, it means calling this function again at the same
--    split point on the same original series correctly hits the
--    "series already cancelled" rejection on the SPLIT series rather
--    than silently re-processing an occurrence range that was already
--    dealt with (there is no RPC in this module that would revisit
--    an already-cancelled series' own split point a second time, but
--    leaving the terminal state correctly recorded is what makes that
--    true).
-- 6. New series row: cloned verbatim from the source series in every
--    field — organization_id, created_by, recurrence_pattern,
--    interval_count, days_of_week, all template_* fields, template_
--    room_id, is_draft_series — since this function takes no content-
--    editing parameters at all (only p_cancellation_reason), there is
--    nothing to COALESCE against, unlike update_series_this_and_
--    future()'s own new-series construction. series_start_date is set
--    to the split date; series_end_date is copied from the source
--    series unchanged (the overall recurrence range doesn't change,
--    only where the split falls and that everything from that point
--    ends up cancelled). status is inserted as 'active' and then
--    explicitly set to 'cancelled' after the per-occurrence loop
--    completes (design decision 5), rather than inserted as
--    'cancelled' directly, so the "mark cancelled after processing"
--    semantics stay literal and match cancel_entire_series()'s own
--    two-step mutate-then-status-update sequencing exactly.
-- 7. created_by is copied from the SOURCE series (not set to the
--    caller performing this action), for the identical reason
--    documented in update_series_this_and_future()'s own design
--    decision 7: this preserves whatever authorization outcome
--    already applied to the source series for any future inspection
--    of the new series id, rather than silently reassigning ownership
--    to whichever supervisor happened to perform this particular
--    cancellation.
-- 8. Original series metadata: series_end_date is shrunk to
--    (split_date - 1 day), unconditionally, once a genuine split has
--    happened — identical reasoning and identical unconditional
--    application to design decision 5 above: the original series'
--    own stored range no longer claims to cover the portion that has
--    now been split off and cancelled, regardless of whether anything
--    in that range was actually cancellable. This is always >= the
--    original series' series_start_date, because the first-occurrence
--    collapse (decision 3) already guarantees an earlier occurrence
--    exists in the original series whenever this code path is
--    reached. No other original-series column is touched — status
--    remains 'active', exactly as the architecture requires ("original
--    series remains active").
-- 9. cancel_entire_series() is deliberately NOT called for a genuine
--    split's per-occurrence work, even though pass 2's cancellation
--    loop is conceptually similar to it. Calling it here would insert
--    its own unconditional audit row and its own conditional
--    notification tied to record_id = the new series id — but with no
--    way to distinguish "this was reached via a this-and-future split"
--    from "this was a direct entire-series cancel" in the audit trail,
--    and, more importantly, cancel_entire_series() re-derives its own
--    v_series (by re-querying meeting_series for p_series_id inside
--    its own body) and re-runs its own full authorization/existence/
--    cancelled-series checks against the NEW series id — which would
--    require this function to have already committed the new series
--    row with a discoverable, stable state before delegating, adding
--    complexity for no behavioral gain over simply reusing the same
--    per-occurrence cancel_meeting() primitive directly, exactly as
--    cancel_entire_series() itself does. Instead, pass 2 calls
--    cancel_meeting() directly, and this function writes its own
--    single audit row and single notification once, after both passes
--    complete, using the same 'meeting_series_cancelled' action/type
--    value cancel_entire_series() already uses (design decision 10) —
--    since the end state and meaning ("this series is now cancelled")
--    is identical regardless of which path reached it, only the
--    record_id and the audit note's scope differ.
-- 10. audit_logs.notes summary format for a genuine split-then-cancel
--     (mirroring update_series_this_and_future()'s own scope=
--     this_and_future notes format, and cancel_entire_series()'s own
--     count fields): 'scope=this_and_future; source_series=<old id>;
--     split_date=<date>; affected=<count>; skipped=<count>;
--     skipped_locked=<count>; skipped_completed=<count>;
--     skipped_cancelled=<count>; skipped_detached=<count>'.
--     record_type='meeting_series', record_id = the NEW series id,
--     action='meeting_series_cancelled'. Written exactly once per
--     genuine-split call, unconditionally (design decision 5). The
--     first-occurrence collapse case instead produces exactly
--     cancel_entire_series()'s own single audit row (record_id = the
--     original series) — see design decision 3 — so this function
--     itself never writes a second one in that branch.
-- 11. Exactly ONE consolidated notification is emitted for a genuine
--     split — participant-facing only, mirroring the single-
--     consolidated-notification-type decision already established
--     throughout this module, for the identical reason: cancel_
--     meeting()'s own direct handling of any linked room booking
--     needs no separate room-manager-facing notification from this
--     bulk RPC. It fires only when at least one occurrence was
--     actually cancelled (v_cancelled_count > 0) — unlike the "mark
--     cancelled" status transition (decision 5), which is
--     unconditional, a notification about occurrences being cancelled
--     when none actually were would be actively misleading to
--     participants.
-- 12. create_series_exception() is never called by this function, for
--     the identical reason it is never called by cancel_entire_series()
--     or update_series_this_and_future(): nothing in this function's
--     own scope produces a new skip or a new move — it only relocates
--     and cancels occurrences that were already active, attached, and
--     future before this call started. A detached or modified
--     occurrence's own meeting_series_exceptions row, if any, is never
--     touched — it already, and correctly, continues to reference the
--     OLD series id, since that occurrence itself was never repointed.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION cancel_series_this_and_future(
  p_meeting_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL
) RETURNS TABLE (meeting_id UUID, occurrence_date DATE, outcome TEXT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_series meeting_series;
  v_new_series_id UUID;
  v_split_date DATE;
  v_occ RECORD;
  v_cancelled_ids UUID[] := ARRAY[]::UUID[];
  v_cancelled_count INTEGER := 0;
  v_skipped_completed INTEGER := 0;
  v_skipped_cancelled INTEGER := 0;
  v_skipped_detached INTEGER := 0;
  v_skipped_locked INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_series_this_and_future requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.series_id IS NULL THEN
    RAISE EXCEPTION 'This meeting is not part of a recurring series';
  END IF;

  SELECT * INTO v_series FROM meeting_series WHERE id = v_meeting.series_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting series not found';
  END IF;

  IF v_series.status = 'cancelled' THEN
    RAISE EXCEPTION 'This series has already been cancelled';
  END IF;

  IF NOT can_manage_series(v_series.id) THEN
    RAISE EXCEPTION 'Not authorized to manage this meeting series';
  END IF;

  IF NOT meetings_module_active_for(v_series.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  v_split_date := v_meeting.series_occurrence_date;

  -- Design decision 3: first-occurrence collapse.
  IF NOT EXISTS (
    SELECT 1 FROM meetings
    WHERE series_id = v_series.id AND series_occurrence_date < v_split_date
  ) THEN
    RETURN QUERY SELECT * FROM cancel_entire_series(v_series.id, p_cancellation_reason);
    RETURN;
  END IF;

  -- Design decision 6/7: new series row, cloned verbatim from the source.
  INSERT INTO meeting_series (
    organization_id, created_by, recurrence_pattern, interval_count, days_of_week,
    series_start_date, series_end_date,
    template_title, template_description, template_meeting_type, template_visibility,
    template_start_time, template_end_time, template_timezone,
    template_location_mode, template_external_location, template_virtual_link, template_room_id,
    is_draft_series, status
  ) VALUES (
    v_series.organization_id, v_series.created_by, v_series.recurrence_pattern,
    v_series.interval_count, v_series.days_of_week,
    v_split_date, v_series.series_end_date,
    v_series.template_title, v_series.template_description,
    v_series.template_meeting_type, v_series.template_visibility,
    v_series.template_start_time, v_series.template_end_time, v_series.template_timezone,
    v_series.template_location_mode, v_series.template_external_location, v_series.template_virtual_link,
    v_series.template_room_id, v_series.is_draft_series, 'active'
  ) RETURNING id INTO v_new_series_id;

  -- Design decision 4: pass 1 — classify and repoint.
  FOR v_occ IN
    SELECT * FROM meetings
    WHERE series_id = v_series.id AND series_occurrence_date >= v_split_date
    ORDER BY series_occurrence_date
  LOOP
    IF v_occ.status = 'cancelled' THEN
      v_skipped_cancelled := v_skipped_cancelled + 1;
      meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'skipped_cancelled';
      RETURN NEXT;
      CONTINUE;
    END IF;
    IF v_occ.series_detached THEN
      v_skipped_detached := v_skipped_detached + 1;
      meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'skipped_detached';
      RETURN NEXT;
      CONTINUE;
    END IF;
    IF v_occ.end_at < now() THEN
      v_skipped_completed := v_skipped_completed + 1;
      meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'skipped_completed';
      RETURN NEXT;
      CONTINUE;
    END IF;
    IF v_occ.is_locked AND NOT is_meeting_lock_overridable(v_occ.id) THEN
      v_skipped_locked := v_skipped_locked + 1;
      meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'skipped_locked';
      RETURN NEXT;
      CONTINUE;
    END IF;

    UPDATE meetings SET series_id = v_new_series_id WHERE id = v_occ.id;
  END LOOP;

  -- Design decision 4/9: pass 2 — cancel only what pass 1 repointed.
  FOR v_occ IN
    SELECT * FROM meetings WHERE series_id = v_new_series_id ORDER BY series_occurrence_date
  LOOP
    PERFORM cancel_meeting(
      p_meeting_id := v_occ.id,
      p_cancellation_reason := p_cancellation_reason,
      p_suppress_notification := TRUE
    );

    v_cancelled_count := v_cancelled_count + 1;
    v_cancelled_ids := array_append(v_cancelled_ids, v_occ.id);
    meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'cancelled';
    RETURN NEXT;
  END LOOP;

  -- Design decision 5: mark the split series cancelled, unconditionally.
  UPDATE meeting_series SET status = 'cancelled' WHERE id = v_new_series_id;

  -- Design decision 8: shrink the original series' own range, unconditionally.
  UPDATE meeting_series SET series_end_date = (v_split_date - 1) WHERE id = v_series.id;

  -- Design decision 10: one consolidated audit row.
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'meeting_series_cancelled', 'meeting_series', v_new_series_id,
    'scope=this_and_future; source_series=' || v_series.id || '; split_date=' || v_split_date ||
    '; affected=' || v_cancelled_count ||
    '; skipped=' || (v_skipped_completed + v_skipped_cancelled + v_skipped_detached + v_skipped_locked) ||
    '; skipped_locked=' || v_skipped_locked ||
    '; skipped_completed=' || v_skipped_completed ||
    '; skipped_cancelled=' || v_skipped_cancelled ||
    '; skipped_detached=' || v_skipped_detached
  );

  -- Design decision 11: one consolidated, participant-facing notification.
  IF v_cancelled_count > 0 THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT DISTINCT mp.user_id, 'meeting_series_cancelled', 'meeting_series', v_new_series_id,
      v_cancelled_count || ' occurrence' || (CASE WHEN v_cancelled_count = 1 THEN '' ELSE 's' END) ||
      ' of the "' || v_series.template_title || '" series ' ||
      (CASE WHEN v_cancelled_count = 1 THEN 'has' ELSE 'have' END) || ' been cancelled.'
    FROM meeting_participants mp
    WHERE mp.meeting_id = ANY(v_cancelled_ids)
      AND mp.user_id IS NOT NULL
      AND mp.removed_at IS NULL
      AND mp.user_id <> v_actor;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
