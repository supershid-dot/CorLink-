-- ============================================================
-- CorLink — Recurring Meetings Phase 2: Preserve Series Membership
-- During Bulk Updates
-- ============================================================
-- Scope, precisely: this patch fixes the bulk-update blocker found in
-- the regression review of commit b97a3a0 (update_series_this_and_
-- future()). It:
--   1. Adds exactly one new trailing parameter,
--      p_preserve_series_membership BOOLEAN DEFAULT FALSE, to the
--      existing update_meeting().
--   2. Makes update_meeting()'s series_detached bookkeeping
--      conditional on that flag — nothing else about update_meeting()
--      changes.
--   3. Redefines update_entire_series() and update_series_this_and_
--      future() so their own internal update_meeting() calls pass
--      p_preserve_series_membership := TRUE — nothing else about
--      either function changes.
--
-- Nothing else changes. cancel_meeting(), reschedule_booking(),
-- can_manage_series(), create_series_exception() are not touched by
-- this patch. No new RPC is introduced. No CHECK constraint is
-- touched — no new notification type or audit action is needed, since
-- this patch changes bookkeeping logic only, not what gets recorded.
--
-- Requires patch-meetings-recurring-phase2-notification-suppression.sql
-- (update_meeting()'s current 13-parameter body, sourced from there),
-- patch-meetings-recurring-phase2-update-entire-series.sql, and
-- patch-meetings-recurring-phase2-update-series-this-and-future.sql
-- already applied.
--
-- ─── The bug this patch fixes ────────────────────────────────────
-- update_meeting()'s UPDATE statement has always included:
--   series_detached = CASE WHEN series_id IS NOT NULL THEN TRUE ELSE series_detached END
-- unconditionally, for every call, regardless of caller. This is
-- correct and intended for a direct, individual edit of one
-- occurrence (that's what "detached" is supposed to mean: this one
-- occurrence was edited outside of any series-wide operation and
-- should no longer be touched by one). But update_entire_series() and
-- update_series_this_and_future() both reuse update_meeting() as
-- their own per-occurrence mutation primitive (Phase 2's own reuse
-- requirement) with no way to tell it "this edit is happening on the
-- series' own behalf, not as an individual override" — so every
-- occurrence either bulk RPC successfully updates gets marked
-- series_detached = TRUE as an unavoidable side effect. The next time
-- either bulk RPC is called on that same series, every occurrence it
-- previously touched now classifies as skipped_detached (the exact
-- same category a genuinely, individually-edited occurrence gets),
-- and the call silently updates nothing. Confirmed reproducible
-- against both RPCs before this fix: a second update_entire_series()
-- call on an already-once-edited series returns 100% skipped_detached
-- with zero occurrences actually updated, no error raised.
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. p_preserve_series_membership is a new TRAILING parameter (after
--    p_suppress_notification, at the very end), not inserted earlier
--    in the list — matching this module's own established convention
--    of always appending new optional parameters at the end (see
--    p_suppress_notification's own addition), so every existing named-
--    argument call site (Supabase's calling convention resolves by
--    name, not position) keeps working unmodified with no frontend
--    change required.
-- 2. DROP FUNCTION IF EXISTS update_meeting(<old 13-parameter
--    signature>) is required before the CREATE OR REPLACE below —
--    Postgres treats a changed argument list as a distinct function
--    identity; without dropping the old signature first, both
--    overloads would coexist and an existing named-argument call
--    (matching both) would fail with "function is not unique" — the
--    same precaution already documented and required by every prior
--    parameter addition to update_meeting()/cancel_meeting()/
--    reschedule_booking() in this module. update_entire_series() and
--    update_series_this_and_future() do NOT need a DROP FUNCTION
--    first: their own external signatures are unchanged by this
--    patch — only their function bodies (a single added named
--    argument on their internal update_meeting() call) are being
--    replaced, which CREATE OR REPLACE FUNCTION handles directly for
--    an identical signature.
-- 3. The only behavioral change inside update_meeting() is the
--    series_detached CASE expression:
--      Before: CASE WHEN series_id IS NOT NULL THEN TRUE ELSE series_detached END
--      After:  CASE WHEN series_id IS NOT NULL AND NOT p_preserve_series_membership THEN TRUE ELSE series_detached END
--    With p_preserve_series_membership left at its default (FALSE),
--    this CASE expression is byte-for-byte equivalent to the original
--    (NOT FALSE = TRUE, so the AND has no effect) — every existing
--    direct-edit call site, and every existing automated test of
--    update_meeting()'s detachment behavior, keeps working exactly as
--    before with no call-site change required. Only a caller that
--    explicitly passes TRUE gets the new behavior: series_detached is
--    left exactly as it already was (FALSE stays FALSE; and if it
--    were already TRUE for some other reason, it stays TRUE — this
--    flag only ever suppresses a FALSE-to-TRUE transition, it never
--    forces a TRUE occurrence back to FALSE, since re-attaching an
--    already-detached occurrence is not this flag's job and isn't
--    part of the locked Phase 2 architecture).
-- 4. Every other line of update_meeting() — the authenticated-caller
--    check, the cancelled-meeting check, the lock check, can_manage_
--    meeting(), meetings_module_active_for(), the status-transition
--    validation, the blank-title check, the end-after-start check,
--    the location-mode field requirements, the reschedule_booking()
--    call (still receiving p_suppress_notification exactly as
--    before), the audit_logs INSERT, and both notification branches
--    (still gated on p_suppress_notification exactly as before) are
--    byte-for-byte unchanged from the version shipped in patch-
--    meetings-recurring-phase2-notification-suppression.sql.
-- 5. update_entire_series() and update_series_this_and_future() each
--    change in exactly one place: their own PERFORM update_meeting(...)
--    call gains one more named argument,
--    p_preserve_series_membership := TRUE, appended after the
--    existing p_suppress_notification := TRUE. Every other line in
--    both functions — the authorization/existence/cancelled-series/
--    module-active checks, the lifecycle-exclusion classification,
--    the time-of-day propagation formula, the repoint-then-update
--    two-pass ordering, the audit_logs/notifications INSERTs, the
--    RETURNS TABLE shape — is byte-for-byte unchanged from what
--    shipped in b9df761 and b97a3a0 respectively.
-- 6. This flag deliberately does not, and does not need to, touch
--    meeting_series_exceptions, meetings.status, or any other column:
--    the entire fix is scoped to the one CASE expression that was
--    over-eagerly detaching bulk-updated occurrences.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. update_meeting(): add p_preserve_series_membership ────────
-- Old signature (13 parameters, from patch-meetings-recurring-
-- phase2-notification-suppression.sql):
--   update_meeting(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ,
--                  TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, BOOLEAN)
DROP FUNCTION IF EXISTS update_meeting(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION update_meeting(
  p_meeting_id UUID,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_meeting_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_timezone TEXT DEFAULT NULL,
  p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL,
  p_virtual_link TEXT DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE,
  p_preserve_series_membership BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
  v_new_status TEXT;
  v_publishing BOOLEAN;
  v_time_changed BOOLEAN;
  v_meaningful_change BOOLEAN;
  v_new_start TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
  v_new_tz TEXT;
  v_new_location_mode TEXT;
  v_new_external_location TEXT;
  v_new_virtual_link TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot update a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may modify it';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to update this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_status IS NOT NULL THEN
    IF p_status = 'cancelled' THEN
      RAISE EXCEPTION 'Use cancel_meeting to cancel a meeting';
    END IF;
    IF p_status = 'draft' AND v_meeting.status = 'scheduled' THEN
      RAISE EXCEPTION 'A scheduled meeting cannot return to draft';
    END IF;
    IF p_status NOT IN ('draft', 'scheduled') THEN
      RAISE EXCEPTION 'Invalid status for update_meeting: %', p_status;
    END IF;
    v_new_status := p_status;
  ELSE
    v_new_status := v_meeting.status;
  END IF;
  v_publishing := (v_meeting.status = 'draft' AND v_new_status = 'scheduled');

  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;

  v_new_start := COALESCE(p_start_at, v_meeting.start_at);
  v_new_end := COALESCE(p_end_at, v_meeting.end_at);
  v_new_tz := COALESCE(p_timezone, v_meeting.timezone);
  IF v_new_end <= v_new_start THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;
  v_time_changed := (p_start_at IS NOT NULL OR p_end_at IS NOT NULL OR p_timezone IS NOT NULL);

  v_new_location_mode := COALESCE(p_location_mode, v_meeting.location_mode);
  v_new_external_location := COALESCE(p_external_location, v_meeting.external_location);
  v_new_virtual_link := COALESCE(p_virtual_link, v_meeting.virtual_link);
  IF v_new_location_mode = 'external' AND v_new_external_location IS NULL THEN
    RAISE EXCEPTION 'external_location is required when location_mode is external';
  END IF;
  IF v_new_location_mode = 'virtual' AND (v_new_virtual_link IS NULL OR v_new_virtual_link !~ '^https://') THEN
    RAISE EXCEPTION 'A valid https:// virtual_link is required when location_mode is virtual';
  END IF;

  v_meaningful_change := (
    p_title IS NOT NULL OR v_time_changed OR p_location_mode IS NOT NULL
    OR p_external_location IS NOT NULL OR p_virtual_link IS NOT NULL
  );

  UPDATE meetings SET
    title = COALESCE(p_title, title),
    description = COALESCE(p_description, description),
    meeting_type = COALESCE(p_meeting_type, meeting_type),
    visibility = COALESCE(p_visibility, visibility),
    status = v_new_status,
    start_at = v_new_start,
    end_at = v_new_end,
    timezone = v_new_tz,
    location_mode = v_new_location_mode,
    external_location = v_new_external_location,
    virtual_link = v_new_virtual_link,
    series_detached = CASE WHEN series_id IS NOT NULL AND NOT p_preserve_series_membership THEN TRUE ELSE series_detached END
  WHERE id = p_meeting_id;

  IF v_time_changed THEN
    SELECT * INTO v_booking FROM meeting_room_bookings
      WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
    IF FOUND THEN
      PERFORM reschedule_booking(v_booking.id, NULL, v_new_start, v_new_end, v_new_tz, p_suppress_notification := p_suppress_notification);
    END IF;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'edited', 'meeting', p_meeting_id);

  IF NOT p_suppress_notification THEN
    IF v_publishing THEN
      INSERT INTO notifications (user_id, type, record_type, record_id, message)
      SELECT uid, 'meeting_created', 'meeting', p_meeting_id,
        'You have been invited to a meeting: ' || COALESCE(p_title, v_meeting.title)
      FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
    ELSIF v_meaningful_change AND v_new_status = 'scheduled' THEN
      INSERT INTO notifications (user_id, type, record_type, record_id, message)
      SELECT uid, 'meeting_updated', 'meeting', p_meeting_id, 'A meeting you are part of was updated.'
      FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
    END IF;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. update_entire_series(): pass p_preserve_series_membership ─
-- Signature unchanged from patch-meetings-recurring-phase2-update-
-- entire-series.sql. Only the internal PERFORM update_meeting(...)
-- call changes: p_preserve_series_membership := TRUE is appended.
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
      p_suppress_notification := TRUE,
      p_preserve_series_membership := TRUE
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

-- ─── 3. update_series_this_and_future(): pass p_preserve_series_membership ─
-- Signature unchanged from patch-meetings-recurring-phase2-update-
-- series-this-and-future.sql. Only the internal PERFORM
-- update_meeting(...) call (pass 2) changes:
-- p_preserve_series_membership := TRUE is appended.
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
      p_suppress_notification := TRUE,
      p_preserve_series_membership := TRUE
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
