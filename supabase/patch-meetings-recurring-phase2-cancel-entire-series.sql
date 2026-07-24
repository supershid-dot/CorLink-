-- ============================================================
-- CorLink — Recurring Meetings Phase 2: "Cancel Entire Series" RPC
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- cancel_entire_series(p_series_id UUID, p_cancellation_reason TEXT)
-- RETURNS TABLE (meeting_id UUID, occurrence_date DATE, outcome
-- TEXT).
--
-- Nothing else changes. cancel_series_this_and_future() is not
-- implemented here. No frontend, no documentation.
--
-- Requires patch-meetings-recurring.sql (meeting_series.status),
-- patch-meetings-recurring-phase2-notification-suppression.sql
-- (cancel_meeting()'s p_suppress_notification parameter, reused here
-- rather than re-implemented), patch-meetings-recurring-phase2-
-- series-auth.sql (can_manage_series()), and patch-meetings-
-- recurring-phase2-preserve-series-membership.sql (only for a
-- consistent, already-applied baseline — this patch does not call or
-- depend on the p_preserve_series_membership parameter, since
-- cancel_meeting() has no equivalent concern: a cancelled occurrence
-- is terminal, there is no "cancel it again later" operation for
-- series_detached-style bookkeeping to protect against) already
-- applied.
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. Check order mirrors update_entire_series() and update_series_
--    this_and_future() exactly: authenticated caller -> series
--    exists -> series not already cancelled -> authorized -> module
--    active -> per-occurrence work. "Reject a series already marked
--    cancelled" is checked before authorization, for the identical
--    reason documented in update_entire_series()'s own design
--    decision 1: whether a record can be acted on at all is a
--    property of the record, independent of who is asking.
-- 2. Per-occurrence lifecycle exclusion uses the exact same skip-and-
--    report model and the exact same four classification categories
--    as update_entire_series() and update_series_this_and_future() —
--    skipped_cancelled, skipped_detached, skipped_completed,
--    skipped_locked — checked in the same order, against the same
--    conditions (status = 'cancelled'; series_detached; end_at <
--    now(); is_locked AND NOT is_meeting_lock_overridable()). No
--    occurrence's exclusion ever aborts the whole call; only a
--    genuine runtime failure aborts and rolls back everything
--    processed so far, via ordinary single-transaction PL/pgSQL
--    semantics. One such genuine-failure path is structural here,
--    not hypothetical: cancel_meeting() itself raises 'A
--    cancellation reason is required' whenever the calling actor is
--    not that specific occurrence's own creator and no
--    p_cancellation_reason was supplied — this RPC does not
--    duplicate or pre-empt that check; it is left to fire exactly as
--    it already does for a direct cancel_meeting() call, and
--    correctly aborts the whole series-wide cancellation if it does
--    (the same "genuine runtime failure" category a real room
--    conflict occupies in the update RPCs).
-- 3. skipped_cancelled/skipped_detached both structurally cover every
--    "skipped" and every "modified" (moved) occurrence under the
--    locked design, for the identical reason documented in update_
--    entire_series()'s own design decision 4 and update_series_this_
--    and_future()'s design decision 5 — the same underlying
--    mechanisms (cancel_meeting()'s status transition, update_
--    meeting()'s unconditional series_detached bookkeeping) are what
--    this function reads. A detached or modified occurrence's own
--    meeting_series_exceptions row, if any, is never touched by this
--    function — it already, and correctly, continues to reference
--    this series' id regardless of whether the series itself is
--    later cancelled.
-- 4. Every eligible occurrence is cancelled by delegating to the
--    existing cancel_meeting() with p_suppress_notification := TRUE
--    — no direct UPDATE against meetings or meeting_room_bookings
--    anywhere in this function. This reuses cancel_meeting()'s own
--    validation (the already-cancelled/draft/locked/authorization/
--    module-active checks — all structurally unreachable here for a
--    pre-filtered eligible occurrence, except authorization and the
--    cancellation-reason requirement, both of which remain live and
--    meaningful per-occurrence exactly as they already are for a
--    direct call), its own per-meeting audit_logs 'cancelled' row
--    (left fully intact — the same per-meeting audit trail an
--    ordinary single-meeting cancellation already produces), and its
--    own direct handling of any linked room booking (a plain UPDATE
--    of the existing booking row to status = 'cancelled', never a
--    call to any other notification-producing RPC) — so booking ids
--    are preserved structurally, exactly as update_entire_series()
--    and update_series_this_and_future() already preserve meeting
--    ids: this function contains no INSERT or DELETE against
--    meetings or meeting_room_bookings anywhere.
-- 5. create_series_exception() is never called by this function.
--    Cancelling the entire series is not a skip or a move of any
--    individual occurrence — it is a series-level state transition —
--    so manufacturing per-occurrence exception rows here would be
--    scope creep beyond what "cancel entire series" means, exactly
--    mirroring update_entire_series()'s own design decision 6.
-- 6. meeting_series.status is set to 'cancelled' unconditionally
--    after the per-occurrence loop completes, regardless of how many
--    occurrences were actually eligible to be cancelled (even zero —
--    e.g. a series where every future occurrence already happens to
--    be individually cancelled, completed, detached, or locked). This
--    is a deliberate difference from update_series_this_and_future()'s
--    own tentative-series pattern (which discards an empty split):
--    cancelling the series is the actual, primary effect of this
--    call, not a byproduct of successfully touching at least one
--    occurrence, and the architecture requirement is explicit and
--    unconditional ("After processing, set meeting_series.status =
--    'cancelled'"). Once set, can_manage_series() is unaffected
--    (it does not consult status), but every mutating series-level
--    RPC that checks v_series.status = 'cancelled' up front —
--    update_entire_series(), update_series_this_and_future(), and
--    this function itself on any later call — now correctly rejects
--    any further action against this series.
-- 7. Exactly ONE consolidated notification is emitted — participant-
--    facing only, mirroring the single-consolidated-notification-type
--    decision already established for update_entire_series() (its
--    design decision 9) and update_series_this_and_future() (its
--    design decision 14), for the identical reason: cancel_meeting()'s
--    own direct handling of any linked room booking needs no separate
--    room-manager-facing notification from this bulk RPC, since that
--    booking is simply cancelled in place with no notification of its
--    own even in the single-meeting case (see cancel_meeting()'s own
--    documented behavior in patch-meetings-recurring-phase2-
--    notification-suppression.sql). The notification fires only when
--    at least one occurrence was actually cancelled — unlike the
--    update RPCs, there is no separate "was this change meaningful"
--    condition to re-derive, since a cancellation is unconditionally
--    meaningful to every affected participant whenever it happens at
--    all.
-- 8. audit_logs.notes summary format (matching the locked format
--    already established for update_entire_series() and update_
--    series_this_and_future()): 'scope=entire_series;
--    affected=<count>; skipped=<count>; skipped_locked=<count>;
--    skipped_completed=<count>; skipped_cancelled=<count>;
--    skipped_detached=<count>'. record_type='meeting_series',
--    record_id=series_id, action='meeting_series_cancelled'. Written
--    exactly once per call, unconditionally (even when affected=0),
--    exactly mirroring update_entire_series()'s own unconditional
--    audit write.
-- 9. New CHECK-constraint value: 'meeting_series_cancelled' is added
--    to both audit_logs.action and notifications.type, each as a
--    full restatement of the verified-current list (this codebase's
--    own established convention — the lists restated here are
--    exactly the ones patch-meetings-recurring-phase2-update-series-
--    this-and-future.sql most recently set, plus this one new
--    trailing value). It is kept distinct from 'meeting_series_
--    updated' and 'meeting_series_split' for the same reason those
--    two are kept distinct from each other: a cancellation is a
--    materially different, terminal event, and an auditor or
--    participant should be able to tell it apart from an edit or a
--    split without inspecting further state.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. Extend audit_logs.action CHECK — full restatement ─────────
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned',
    'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden',
    'unassigned', 'participant_added', 'participant_removed',
    'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked',
    'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked',
    'meeting_group_created', 'meeting_group_updated', 'meeting_group_deleted',
    'meeting_group_members_updated',
    'meeting_series_created',
    'meeting_draft_deleted',
    'meeting_series_updated',
    'meeting_series_split',
    'meeting_series_cancelled'
  ));

-- ─── 2. Extend notifications.type CHECK — full restatement ────────
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention',
    'meeting_created', 'participant_added', 'meeting_updated',
    'room_assigned', 'meeting_cancelled', 'participant_removed',
    'participant_responded',
    'meeting_series_created',
    'recurring_booking_submitted',
    'meeting_series_updated',
    'meeting_series_split',
    'meeting_series_cancelled'
  ));

-- ─── 3. cancel_entire_series() ──────────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_entire_series(
  p_series_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL
) RETURNS TABLE (meeting_id UUID, occurrence_date DATE, outcome TEXT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_series meeting_series;
  v_occ RECORD;
  v_cancelled_ids UUID[] := ARRAY[]::UUID[];
  v_cancelled_count INTEGER := 0;
  v_skipped_completed INTEGER := 0;
  v_skipped_cancelled INTEGER := 0;
  v_skipped_detached INTEGER := 0;
  v_skipped_locked INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_entire_series requires an authenticated caller';
  END IF;

  SELECT * INTO v_series FROM meeting_series WHERE id = p_series_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting series not found';
  END IF;

  IF v_series.status = 'cancelled' THEN
    RAISE EXCEPTION 'This series has already been cancelled';
  END IF;

  IF NOT can_manage_series(p_series_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this meeting series';
  END IF;

  IF NOT meetings_module_active_for(v_series.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  FOR v_occ IN
    SELECT * FROM meetings WHERE series_id = p_series_id ORDER BY series_occurrence_date
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

  UPDATE meeting_series SET status = 'cancelled' WHERE id = p_series_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'meeting_series_cancelled', 'meeting_series', p_series_id,
    'scope=entire_series; affected=' || v_cancelled_count ||
    '; skipped=' || (v_skipped_completed + v_skipped_cancelled + v_skipped_detached + v_skipped_locked) ||
    '; skipped_locked=' || v_skipped_locked ||
    '; skipped_completed=' || v_skipped_completed ||
    '; skipped_cancelled=' || v_skipped_cancelled ||
    '; skipped_detached=' || v_skipped_detached
  );

  IF v_cancelled_count > 0 THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT DISTINCT mp.user_id, 'meeting_series_cancelled', 'meeting_series', p_series_id,
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
