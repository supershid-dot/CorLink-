-- ============================================================
-- CorLink — Recurring Meetings Phase 2: "Update This and Future" RPC
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- update_series_this_and_future(p_meeting_id UUID, p_title TEXT,
-- p_description TEXT, p_meeting_type TEXT, p_visibility TEXT,
-- p_start_time TIME, p_end_time TIME, p_timezone TEXT,
-- p_location_mode TEXT, p_external_location TEXT, p_virtual_link
-- TEXT) RETURNS TABLE (meeting_id UUID, occurrence_date DATE, outcome
-- TEXT).
--
-- Nothing else changes. cancel_entire_series() and
-- cancel_series_this_and_future() are not implemented here. No
-- frontend, no documentation.
--
-- Requires patch-meetings-recurring.sql, patch-meetings-recurring-
-- phase2-notification-suppression.sql, patch-meetings-recurring-
-- phase2-series-auth.sql, and patch-meetings-recurring-phase2-update-
-- entire-series.sql already applied (this function calls
-- update_entire_series() directly for the first-occurrence collapse
-- case — see design decision 2).
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. The split point is identified by p_meeting_id — the specific
--    occurrence row the caller is editing "this and future" from —
--    rather than by a series id plus a date. This matches how the
--    action is actually initiated (from a specific occurrence's own
--    edit UI, which already has a concrete meeting id in hand) and
--    avoids trusting the caller to correctly compute/pass a date that
--    must exactly match an existing series_occurrence_date. The
--    series id and split date are both derived server-side from this
--    one input: v_series_id := meetings.series_id,
--    v_split_date := meetings.series_occurrence_date.
-- 2. First-occurrence collapse (locked architecture requirement):
--    if no occurrence in the series has a series_occurrence_date
--    earlier than the split occurrence's own date, "this and future"
--    is definitionally identical to "the entire series" — nothing
--    would be left behind in the old series, so splitting into two
--    series rows would be pure overhead with no observable
--    difference. This function detects that case
--    (NOT EXISTS an earlier occurrence in the same series) and
--    short-circuits directly to
--    RETURN QUERY SELECT * FROM update_entire_series(...), passing
--    the SAME series id through unchanged — no new series is created,
--    no repointing happens, and update_entire_series()'s own single
--    audit row and single notification (action/type=
--    'meeting_series_updated', record_id = the original series) are
--    the only ones produced for this call. This is the only call site
--    in this function that invokes update_entire_series() — seedesign
--    decision 12 for why a genuine split does NOT also delegate to it.
-- 3. Two-pass split algorithm for a genuine split (locked
--    architecture requirement): occurrences with
--    series_occurrence_date >= the split date are first classified
--    exactly like update_entire_series() classifies every occurrence
--    (cancelled -> skipped_cancelled, series_detached ->
--    skipped_detached, end_at < now() -> skipped_completed, locked
--    and not overridable by this caller -> skipped_locked; anything
--    else is eligible). Pass 1 repoints ONLY the eligible occurrences'
--    own meetings.series_id to the new series — nothing else about
--    those rows changes in this pass, and lifecycle-excluded
--    occurrences are never repointed at all, regardless of how far in
--    the future they fall: they stay exactly where they are, attached
--    to the OLD series, in whatever state they were already in. Pass
--    2 then applies the requested field edits — but only after pass 1
--    has finished repointing, and only to the occurrences that pass 1
--    actually repointed (selected via
--    WHERE series_id = v_new_series_id, which after pass 1 is exactly
--    and only that set). This ordering is a locked architecture
--    requirement, not an implementation preference: it guarantees the
--    new series never contains an occurrence pass 2 hasn't accounted
--    for, and that pass 2 never has to re-derive eligibility.
-- 4. Occurrences dated BEFORE the split date are never inspected,
--    classified, or touched by either pass, regardless of their own
--    lifecycle state — they unconditionally remain with the old
--    series exactly as they already were. Only the
--    series_occurrence_date >= split date window is ever in scope.
-- 5. skipped_cancelled/skipped_detached both structurally cover every
--    "skipped" and every "modified" (moved) occurrence under the
--    locked design, exactly as documented in update_entire_series()'s
--    own design decision 4 — the identical convergence applies here
--    for the identical reason (update_meeting()'s own unconditional
--    series_detached bookkeeping, and cancel_meeting()'s status
--    change, are the same underlying mechanisms this function reads).
--    A skipped or modified occurrence's meeting_series_exceptions row
--    is never touched by this function either way — it already, and
--    correctly, continues to reference the OLD series id, since the
--    occurrence itself was never repointed.
-- 6. create_series_exception() is never called by this function, for
--    the same reason update_entire_series() never calls it (see that
--    patch's design decision 6): nothing in this function's own scope
--    produces a new skip or a new move — it only relocates and edits
--    occurrences that were already active, attached, and future
--    before this call started.
-- 7. New series row: organization_id, created_by, recurrence_pattern,
--    interval_count, days_of_week, is_draft_series, and
--    template_room_id are copied verbatim from the source series —
--    this is a continuation of the same recurring series, not a
--    logically distinct one, so its shape and ownership carry over
--    unchanged. created_by is deliberately copied from the SOURCE
--    series (not set to the caller performing this split): this
--    preserves whatever authorization outcome already applied to the
--    source series (creator-owned, or org-supervisor-managed) for any
--    future call against the new series id, rather than silently
--    reassigning ownership to whichever supervisor happened to
--    perform this particular edit. series_start_date is set to the
--    split date; series_end_date is copied from the source series
--    (the overall recurrence range doesn't change, only where the
--    split falls within it). template_title/description/meeting_type/
--    visibility/start_time/end_time/timezone/location_mode/
--    external_location/virtual_link are each COALESCE(new value,
--    source series' template value) — the same COALESCE-over-existing
--    pattern update_meeting() and update_entire_series() both already
--    use, applied here to the new series' own template row instead of
--    to an occurrence row, so the new series' stored metadata
--    correctly reflects the edit that was just requested rather than
--    silently keeping stale pre-edit values (unlike
--    update_entire_series(), which deliberately leaves template_*
--    alone on an EXISTING series — see that patch's design decision
--    10 — there is no existing row here to leave alone; this row is
--    being created fresh, so populating it correctly costs nothing
--    extra and avoids publishing incorrect metadata for a series that
--    did not exist before this call).
-- 8. Template time-range guard: because meeting_series has its own
--    declarative CHECK (template_end_time > template_start_time),
--    and the new series' template times are computed via COALESCE
--    against the SOURCE series' template (not against the split
--    occurrence's own live start_at/end_at, which for a still-
--    attached, undetached occurrence are always identical to the
--    source series' template by construction), a start-time-only or
--    end-time-only edit could otherwise push the new template's
--    computed range invalid (e.g. source template 09:00-10:00,
--    p_start_time := '10:30' alone would combine with the unedited
--    10:00 into an inverted range). This function checks
--    COALESCE(p_end_time, source.template_end_time) >
--    COALESCE(p_start_time, source.template_start_time) explicitly,
--    before creating anything, and raises the same friendly
--    'end_time must be after start_time' message update_meeting()
--    would eventually raise for the equivalent per-occurrence case in
--    pass 2 — turning what would otherwise surface as a raw
--    constraint-violation error on the meeting_series INSERT into the
--    same clean, expected validation error the rest of this module
--    already uses.
-- 9. Tentative-series pattern: this function does not pre-count
--    eligible occurrences before creating the new series row. It
--    creates the new series, runs pass 1, and if pass 1 repointed
--    zero occurrences (every occurrence from the split date forward
--    was lifecycle-excluded), it deletes the just-created series row
--    before returning — all within the same transaction, so the
--    discarded id is never visible to any other session and no audit
--    or notification is written for a split that split off nothing.
--    This avoids writing the eligibility classification logic twice
--    (once to decide whether to create the series, once again inside
--    the real pass 1 loop) at the cost of one throwaway INSERT+DELETE
--    on the rare all-excluded path — a deliberate simplicity-over-
--    micro-optimization tradeoff.
-- 10. Meeting ids and booking ids are preserved structurally, not by
--     any explicit preservation logic: this function contains no
--     INSERT or DELETE against meetings or meeting_room_bookings
--     anywhere. Pass 1's repoint is a plain UPDATE of the existing
--     row's series_id column; pass 2 delegates every field edit to
--     the existing update_meeting(), whose own nested
--     reschedule_booking() call (when a linked booking exists) is
--     likewise a plain UPDATE of the existing booking row. Nothing in
--     this function's own body is capable of creating or destroying a
--     meetings or meeting_room_bookings row.
-- 11. Old series metadata: series_end_date is shrunk to
--     (split_date - 1 day) once a genuine split has actually
--     happened, so the old series' own stored range no longer claims
--     to cover the portion that now belongs to the new series. This
--     is always >= the old series' series_start_date, because the
--     first-occurrence collapse (decision 2) already guarantees an
--     earlier occurrence exists in the old series whenever this code
--     path is reached, and series_start_date can never be later than
--     that earlier occurrence's own date. No other old-series column
--     is touched.
-- 12. update_entire_series() is deliberately NOT called for a genuine
--     split, even though pass 2's per-occurrence update loop is
--     structurally identical to it (same time-of-day propagation
--     formula, same update_meeting() delegation with
--     p_suppress_notification := TRUE). Calling it here would insert
--     its own unconditional audit row and its own conditional
--     notification, tied to record_id = the new series id, with
--     action/type = 'meeting_series_updated' and no way to suppress
--     either (update_entire_series() takes no suppression parameter,
--     and this patch must leave it unchanged per its own regression
--     requirement) — producing a second, competing audit/notification
--     alongside this function's own, which would violate "one
--     consolidated notification" / "one consolidated audit" for a
--     genuine split. Instead, pass 2 reuses the same underlying
--     primitives update_entire_series() itself uses
--     (update_meeting() with suppression, the identical time-of-day
--     formula) directly, and this function writes its own single
--     audit row and single notification once, after both passes
--     complete — using a distinct action/type value (decision 13) so
--     the audit trail can still tell a split apart from a plain
--     whole-series edit.
-- 13. New CHECK-constraint value: 'meeting_series_split' is added to
--     both audit_logs.action and notifications.type, each as a full
--     restatement of the verified-current list (this codebase's own
--     established convention — the lists restated here are exactly
--     the ones patch-meetings-recurring-phase2-update-entire-
--     series.sql most recently set, plus this one new trailing
--     value). It is kept distinct from 'meeting_series_updated'
--     rather than reused, because a "this and future" split is a
--     materially different, more consequential event (a whole new
--     series row comes into existence and the old one's range
--     shrinks) than a same-series field edit, and an auditor or
--     participant should be able to tell the two apart without
--     inspecting record_id history.
-- 14. Exactly ONE consolidated notification type is emitted for a
--     genuine split — participant-facing only, mirroring update_
--     entire_series()'s own design decision 9 for the identical
--     reason: a second, room-manager-facing notification is
--     unnecessary because update_meeting()'s own nested
--     reschedule_booking() call already handles (and, with
--     suppression on, correctly suppresses) that audience per
--     occurrence.
-- 15. audit_logs.notes summary format for a genuine split:
--     'scope=this_and_future; source_series=<old id>; split_date=
--     <date>; affected=<count>; skipped=<count>; skipped_locked=
--     <count>; skipped_completed=<count>; skipped_cancelled=<count>;
--     skipped_detached=<count>'. record_type='meeting_series',
--     record_id = the NEW series id (the entity whose metadata this
--     call actually set), action='meeting_series_split'. Written
--     exactly once per genuine-split call. The first-occurrence
--     collapse case instead produces exactly update_entire_series()'s
--     own single audit row — see decision 2 — so this function itself
--     never writes a second one in that branch.
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
    'meeting_series_split'
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
    'meeting_series_split'
  ));

-- ─── 3. update_series_this_and_future() ────────────────────────────
CREATE OR REPLACE FUNCTION update_series_this_and_future(
  p_meeting_id UUID,
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
  v_meeting meetings;
  v_series meeting_series;
  v_new_series_id UUID;
  v_split_date DATE;
  v_occ RECORD;
  v_time_requested BOOLEAN;
  v_meaningful_change BOOLEAN;
  v_new_start_at TIMESTAMPTZ;
  v_new_end_at TIMESTAMPTZ;
  v_updated_ids UUID[] := ARRAY[]::UUID[];
  v_updated_count INTEGER := 0;
  v_repointed_count INTEGER := 0;
  v_skipped_completed INTEGER := 0;
  v_skipped_cancelled INTEGER := 0;
  v_skipped_detached INTEGER := 0;
  v_skipped_locked INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_series_this_and_future requires an authenticated caller';
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
    RAISE EXCEPTION 'This series has been cancelled';
  END IF;

  IF NOT can_manage_series(v_series.id) THEN
    RAISE EXCEPTION 'Not authorized to manage this meeting series';
  END IF;

  IF NOT meetings_module_active_for(v_series.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;
  IF COALESCE(p_end_time, v_series.template_end_time) <= COALESCE(p_start_time, v_series.template_start_time) THEN
    RAISE EXCEPTION 'end_time must be after start_time';
  END IF;

  v_split_date := v_meeting.series_occurrence_date;

  -- Design decision 2: first-occurrence collapse.
  IF NOT EXISTS (
    SELECT 1 FROM meetings
    WHERE series_id = v_series.id AND series_occurrence_date < v_split_date
  ) THEN
    RETURN QUERY SELECT * FROM update_entire_series(
      v_series.id, p_title, p_description, p_meeting_type, p_visibility,
      p_start_time, p_end_time, p_timezone,
      p_location_mode, p_external_location, p_virtual_link
    );
    RETURN;
  END IF;

  -- Design decision 7: new series row, cloned shape + edited template.
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
    COALESCE(p_title, v_series.template_title), COALESCE(p_description, v_series.template_description),
    COALESCE(p_meeting_type, v_series.template_meeting_type), COALESCE(p_visibility, v_series.template_visibility),
    COALESCE(p_start_time, v_series.template_start_time), COALESCE(p_end_time, v_series.template_end_time),
    COALESCE(p_timezone, v_series.template_timezone),
    COALESCE(p_location_mode, v_series.template_location_mode),
    COALESCE(p_external_location, v_series.template_external_location),
    COALESCE(p_virtual_link, v_series.template_virtual_link), v_series.template_room_id,
    v_series.is_draft_series, 'active'
  ) RETURNING id INTO v_new_series_id;

  -- Design decision 3: pass 1 — classify and repoint.
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
    v_repointed_count := v_repointed_count + 1;
  END LOOP;

  -- Design decision 9: nothing eligible — discard the tentative series.
  IF v_repointed_count = 0 THEN
    DELETE FROM meeting_series WHERE id = v_new_series_id;
    RETURN;
  END IF;

  -- Design decision 3/12: pass 2 — apply edits only after repointing.
  v_time_requested := (p_start_time IS NOT NULL OR p_end_time IS NOT NULL OR p_timezone IS NOT NULL);
  v_meaningful_change := (
    p_title IS NOT NULL OR v_time_requested OR p_location_mode IS NOT NULL
    OR p_external_location IS NOT NULL OR p_virtual_link IS NOT NULL
  );

  FOR v_occ IN
    SELECT * FROM meetings WHERE series_id = v_new_series_id ORDER BY series_occurrence_date
  LOOP
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

  -- Design decision 11: shrink the old series' own range.
  UPDATE meeting_series SET series_end_date = (v_split_date - 1) WHERE id = v_series.id;

  -- Design decision 15: one consolidated audit row.
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'meeting_series_split', 'meeting_series', v_new_series_id,
    'scope=this_and_future; source_series=' || v_series.id || '; split_date=' || v_split_date ||
    '; affected=' || v_updated_count ||
    '; skipped=' || (v_skipped_completed + v_skipped_cancelled + v_skipped_detached + v_skipped_locked) ||
    '; skipped_locked=' || v_skipped_locked ||
    '; skipped_completed=' || v_skipped_completed ||
    '; skipped_cancelled=' || v_skipped_cancelled ||
    '; skipped_detached=' || v_skipped_detached
  );

  -- Design decision 14: one consolidated, participant-facing notification.
  IF v_updated_count > 0 AND v_meaningful_change THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT DISTINCT mp.user_id, 'meeting_series_split', 'meeting_series', v_new_series_id,
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
