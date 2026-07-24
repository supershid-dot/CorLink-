-- ============================================================
-- CorLink — Recurring Meetings Phase 2: "Update Entire Series" RPC
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- update_entire_series(p_series_id UUID, p_title TEXT, p_description
-- TEXT, p_meeting_type TEXT, p_visibility TEXT, p_start_time TIME,
-- p_end_time TIME, p_timezone TEXT, p_location_mode TEXT,
-- p_external_location TEXT, p_virtual_link TEXT) RETURNS TABLE
-- (meeting_id UUID, occurrence_date DATE, outcome TEXT).
--
-- Nothing else changes. No other recurring-series Phase 2 RPC is
-- implemented here (no update_series_this_and_future(),
-- cancel_entire_series(), cancel_series_this_and_future()). No skip-
-- occurrence or moved-occurrence WORKFLOW is implemented. No
-- frontend, no documentation.
--
-- Requires patch-meetings-recurring.sql (meeting_series/meetings
-- series columns), patch-meetings-recurring-phase2-notification-
-- suppression.sql (update_meeting()'s p_suppress_notification
-- parameter, reused here rather than re-implemented), and
-- patch-meetings-recurring-phase2-series-auth.sql (can_manage_series(),
-- reused here exactly as directed) already applied.
-- patch-meetings-recurring-phase2-series-exceptions.sql is NOT a
-- functional dependency of this patch — create_series_exception() is
-- not called anywhere below (see design decision 6).
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. Check order mirrors every existing mutating RPC in this module
--    exactly: authenticated caller -> series exists -> series not
--    cancelled -> authorized -> module active -> input validation ->
--    per-occurrence work. The task's own requirement list places
--    "reject cancelled series" before "verify authorization" in its
--    numbering, and that is also this codebase's own established
--    order for update_meeting()/cancel_meeting() (both check the
--    record's own cancelled-ness before calling can_manage_meeting())
--    — followed here for the identical reason: whether a record can
--    be acted on at all is a property of the record, independent of
--    who is asking, and is checked first.
-- 2. "Reject cancelled series" closes the gap flagged in the
--    regression review of create_series_exception()
--    (patch-meetings-recurring-phase2-series-exceptions.sql): the
--    earlier-locked Phase 2 architecture decision that a cancelled
--    series freezes all further series-level actions. This is the
--    first RPC in this codebase to actually enforce that rule (no
--    RPC anywhere yet sets meeting_series.status = 'cancelled', so
--    this check is provably inert today and will only become live
--    once a future cancel_entire_series() exists — exactly mirroring
--    how create_series_exception() was written, tested, and reviewed
--    before this check existed).
-- 3. Per-occurrence lifecycle exclusion (the "skip-and-report" model,
--    locked in the Phase 2 architecture round): each occurrence
--    belonging to the series is independently classified into exactly
--    one of five outcomes — updated, skipped_cancelled,
--    skipped_detached, skipped_completed, skipped_locked — and
--    returned as one row per occurrence via RETURN NEXT. No
--    occurrence's exclusion ever aborts the whole call; only a
--    genuine runtime failure (e.g. a real room conflict surfaced by
--    reschedule_booking()'s own conflict-guard trigger, invoked
--    indirectly through update_meeting()) aborts and rolls back
--    everything processed so far, via ordinary single-transaction
--    PL/pgSQL semantics — no special-case handling needed for that.
-- 4. skipped_cancelled (status = 'cancelled') structurally also
--    covers every "skipped" occurrence under the locked design
--    (skipping an occurrence means calling cancel_meeting() on it,
--    per the locked skip-semantics decision) — there is no separate
--    check against meeting_series_exceptions, deliberately: the
--    occurrence's own status is already the authoritative signal.
--    skipped_detached (series_detached = TRUE) structurally also
--    covers every individually-edited occurrence AND every "modified"
--    (moved) occurrence under the locked design, since
--    update_meeting()'s own unconditional bookkeeping
--    (series_detached = CASE WHEN series_id IS NOT NULL THEN TRUE ...)
--    sets that flag as a side effect of any prior edit, including a
--    future move-workflow's time-only shift. Both convergences are
--    intentional, not a test-design flaw — see this patch's companion
--    validation file for three genuinely distinct routes to
--    "detached" tested separately for robustness.
-- 5. Every per-occurrence mutation is delegated to the existing
--    update_meeting() with p_suppress_notification := TRUE — no
--    direct UPDATE against the meetings table anywhere in this
--    function. This reuses update_meeting()'s own validation
--    (blank-title rejection, end-after-start, location-mode
--    field requirements), its own audit_logs 'edited' row per
--    occurrence (left intact — this is the same per-meeting audit
--    trail every ordinary single-meeting edit already produces, not
--    something this bulk RPC suppresses), and its own nested
--    reschedule_booking() call for any occurrence with a linked room
--    booking — which itself already propagates
--    p_suppress_notification (from the notification-suppression
--    foundation patch), so both the participant-facing and any
--    nested room-manager-facing notification are correctly suppressed
--    per occurrence with no additional plumbing needed here.
-- 6. create_series_exception() is never called by this function.
--    Nothing in this RPC's scope produces a skip or a move — it only
--    edits already-active, still-attached, still-future occurrences.
--    Manufacturing exception rows here would be scope creep beyond
--    what "update entire series" means; that responsibility belongs
--    to the not-yet-built skip/move workflow RPCs.
-- 7. Time-of-day propagation: p_start_time/p_end_time/p_timezone edit
--    the TIME-OF-DAY and zone shared by every occurrence, never an
--    occurrence's own fixed series_occurrence_date (dates/pattern
--    stay explicitly out of Phase 2's editable scope). For each
--    occurrence, the new absolute instant is computed as
--    (occurrence's own fixed date + new-or-existing time-of-day) AT
--    TIME ZONE new-or-existing timezone — mirroring
--    create_recurring_meeting()'s own occurrence-generation formula,
--    applied here to existing rows instead of at creation time. The
--    unspecified side of a partial time edit (only start OR only end
--    given) is derived from the occurrence's own current time-of-day
--    via (existing start/end AT TIME ZONE existing timezone)::TIME,
--    so a start-time-only edit does not silently collapse the
--    occurrence's own duration.
-- 8. v_meaningful_change is independently re-derived here using the
--    exact same condition update_meeting() uses internally to decide
--    whether ITS OWN per-occurrence notification would have fired
--    (p_title IS NOT NULL OR time-changed OR p_location_mode IS NOT
--    NULL OR p_external_location IS NOT NULL OR p_virtual_link IS NOT
--    NULL — deliberately NOT description/meeting_type/visibility).
--    This bulk RPC's own single consolidated notification only fires
--    when this condition holds AND at least one occurrence was
--    actually updated — so an "update description only" call (every
--    occurrence's own update_meeting() call would fire zero
--    notifications individually) correctly produces zero consolidated
--    notifications too, not a spurious one.
-- 9. Exactly ONE consolidated notification type is emitted here —
--    participant-facing only. This task's own instructions describe
--    "one consolidated notification (if required)" (singular) and
--    repeatedly frame this step as minimal ("do not manufacture...
--    unnecessarily"); a second, room-manager-facing consolidated
--    notification is not implemented, since update_meeting()'s own
--    per-occurrence reschedule_booking() call already handles (and,
--    with suppression on, correctly suppresses) that audience without
--    this bulk RPC needing to know about room bookings at all. This
--    is a deliberate, narrower reading of the design report's
--    "per-audience" phrasing, not an oversight.
-- 10. meeting_series.template_* fields are deliberately left
--     unmodified by this function. Nothing in the system reads them
--     again after series creation (they exist purely as
--     create_recurring_meeting()'s own generation input); updating
--     them here would be inert work outside this step's scope.
-- 11. New CHECK-constraint values: 'meeting_series_updated' is added
--     to both audit_logs.action and notifications.type, each as a
--     full restatement of the verified-current list (this codebase's
--     own established convention for every such extension — verified
--     via direct pg_get_constraintdef() query against a live test
--     database immediately before writing this patch, to eliminate
--     transcription risk). This mirrors the direct precedent of
--     meeting_series_created, which was introduced as a wholly new
--     value rather than reusing the generic 'created'/'meeting_
--     created', specifically because record_type='meeting_series'
--     warrants distinct semantics from a single meeting's own action/
--     type vocabulary. This codebase's own established vocabulary
--     treats "schema change" as table/column changes specifically —
--     every prior notification/audit-introducing patch in this
--     project has always required a CHECK-value addition as routine,
--     never treated as a schema change; the "no schema changes"
--     regression requirement for this task is satisfied accordingly.
-- 12. audit_logs.notes summary format (locked in the design-
--     confirmation round): 'scope=<scope>; affected=<count>;
--     skipped=<count>; skipped_locked=<count>;
--     skipped_completed=<count>; skipped_cancelled=<count>;
--     skipped_detached=<count>'. scope='entire_series' for this RPC.
--     record_type='meeting_series', record_id=series_id,
--     action='meeting_series_updated'. Written exactly once per call,
--     regardless of how many occurrences were touched or skipped.
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
    'meeting_series_updated'
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
    'meeting_series_updated'
  ));

-- ─── 3. update_entire_series() ─────────────────────────────────────
CREATE OR REPLACE FUNCTION update_entire_series(
  p_series_id UUID,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_meeting_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL,
  p_start_time TIME DEFAULT NULL,
  p_end_time TIME DEFAULT NULL,
  p_timezone TEXT DEFAULT NULL,
  p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL,
  p_virtual_link TEXT DEFAULT NULL
) RETURNS TABLE (meeting_id UUID, occurrence_date DATE, outcome TEXT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_series meeting_series;
  v_occ RECORD;
  v_time_requested BOOLEAN;
  v_meaningful_change BOOLEAN;
  v_new_start_at TIMESTAMPTZ;
  v_new_end_at TIMESTAMPTZ;
  v_updated_ids UUID[] := ARRAY[]::UUID[];
  v_updated_count INTEGER := 0;
  v_skipped_completed INTEGER := 0;
  v_skipped_cancelled INTEGER := 0;
  v_skipped_detached INTEGER := 0;
  v_skipped_locked INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_entire_series requires an authenticated caller';
  END IF;

  SELECT * INTO v_series FROM meeting_series WHERE id = p_series_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting series not found';
  END IF;

  IF v_series.status = 'cancelled' THEN
    RAISE EXCEPTION 'This series has been cancelled';
  END IF;

  IF NOT can_manage_series(p_series_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this meeting series';
  END IF;

  IF NOT meetings_module_active_for(v_series.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;
  IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL AND p_end_time <= p_start_time THEN
    RAISE EXCEPTION 'end_time must be after start_time';
  END IF;

  v_time_requested := (p_start_time IS NOT NULL OR p_end_time IS NOT NULL OR p_timezone IS NOT NULL);
  v_meaningful_change := (
    p_title IS NOT NULL OR v_time_requested OR p_location_mode IS NOT NULL
    OR p_external_location IS NOT NULL OR p_virtual_link IS NOT NULL
  );

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

    IF v_time_requested THEN
      v_new_start_at := (v_occ.series_occurrence_date + COALESCE(p_start_time, (v_occ.start_at AT TIME ZONE v_occ.timezone)::TIME))
        AT TIME ZONE COALESCE(p_timezone, v_occ.timezone);
      v_new_end_at := (v_occ.series_occurrence_date + COALESCE(p_end_time, (v_occ.end_at AT TIME ZONE v_occ.timezone)::TIME))
        AT TIME ZONE COALESCE(p_timezone, v_occ.timezone);
    ELSE
      v_new_start_at := NULL;
      v_new_end_at := NULL;
    END IF;

    PERFORM update_meeting(
      p_meeting_id := v_occ.id,
      p_title := p_title,
      p_description := p_description,
      p_meeting_type := p_meeting_type,
      p_visibility := p_visibility,
      p_start_at := v_new_start_at,
      p_end_at := v_new_end_at,
      p_timezone := p_timezone,
      p_location_mode := p_location_mode,
      p_external_location := p_external_location,
      p_virtual_link := p_virtual_link,
      p_suppress_notification := TRUE
    );

    v_updated_count := v_updated_count + 1;
    v_updated_ids := array_append(v_updated_ids, v_occ.id);
    meeting_id := v_occ.id; occurrence_date := v_occ.series_occurrence_date; outcome := 'updated';
    RETURN NEXT;
  END LOOP;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'meeting_series_updated', 'meeting_series', p_series_id,
    'scope=entire_series; affected=' || v_updated_count ||
    '; skipped=' || (v_skipped_completed + v_skipped_cancelled + v_skipped_detached + v_skipped_locked) ||
    '; skipped_locked=' || v_skipped_locked ||
    '; skipped_completed=' || v_skipped_completed ||
    '; skipped_cancelled=' || v_skipped_cancelled ||
    '; skipped_detached=' || v_skipped_detached
  );

  IF v_updated_count > 0 AND v_meaningful_change THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT DISTINCT mp.user_id, 'meeting_series_updated', 'meeting_series', p_series_id,
      v_updated_count || ' occurrence' || (CASE WHEN v_updated_count = 1 THEN '' ELSE 's' END) ||
      ' of the "' || v_series.template_title || '" series ' ||
      (CASE WHEN v_updated_count = 1 THEN 'has' ELSE 'have' END) || ' been updated.'
    FROM meeting_participants mp
    WHERE mp.meeting_id = ANY(v_updated_ids)
      AND mp.user_id IS NOT NULL
      AND mp.removed_at IS NULL
      AND mp.user_id <> v_actor;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
