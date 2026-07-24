-- ─── Patch: Recurring room-approval notification batching ──────
-- Implements the approved design decision in docs/25-recurring-
-- meetings-phase1-design-decisions.md §3: a recurring series that
-- requires room approval (the creator is not a manager of the target
-- room) must send each relevant room manager exactly ONE consolidated
-- notification for the whole series, not one identical
-- 'booking_submitted' notification per occurrence.
--
-- Scope, precisely: this patch changes ONLY room-approval notification
-- volume for the recurring-series creation path. It does not change:
--   - standalone (non-recurring) booking requests, which continue to
--     fire their existing per-booking 'booking_submitted' notification
--     exactly as before (requirement 1);
--   - any individual meeting_room_bookings row (still one per
--     occurrence, requirement 4);
--   - any individual booking's audit_logs row (still one 'submitted'/
--     'meeting_room_booking' row per occurrence, requirement 5);
--   - the per-booking approval/rejection workflow (approve_booking/
--     reject_booking/cancel_booking are untouched — requirement 6/7);
--   - any existing booking id (requirement 8);
--   - any existing RPC call shape used by the frontend today
--     (requirement 9 — every new parameter is appended with a
--     DEFAULT, so every existing named-argument call site keeps
--     working unchanged).
--
-- Mechanism (requirement 10 — explicit control, not call-ordering):
-- submit_booking_request()/assign_room_booking() each gain one new
-- trailing parameter, p_suppress_notification BOOLEAN DEFAULT FALSE.
-- Every existing caller (the frontend's "Assign Room"/"Change Room"
-- modals, and any other direct RPC caller) omits it and gets FALSE —
-- byte-for-byte the same notification behavior as before this patch.
-- create_recurring_meeting() is the only caller that ever passes
-- TRUE, once per occurrence, then inserts exactly one consolidated
-- notification per room manager after the occurrence loop completes —
-- an explicit, unconditional step, not a side effect of call order.
-- assign_room_booking()'s own 'room_assigned' participant notification
-- is suppressed by the same flag for the same reason: docs/25 §3
-- explicitly warns the future implementation must not depend on
-- assign_room_booking() currently running before add_group_as_
-- participants() (today's accidental, order-dependent reason that
-- notification resolves to zero recipients during series creation).
--
-- Both DROP FUNCTION statements below are required, not decorative —
-- Postgres treats a new/changed argument list as a distinct function
-- identity; without dropping the old 2-arg/7-arg signatures first,
-- both the old and new overloads would coexist, and an existing named-
-- argument call (matching both) would fail with "function is not
-- unique". Mirrors the identical precaution already taken by
-- `DROP FUNCTION IF EXISTS assign_room_booking(UUID, UUID, TIMESTAMPTZ,
-- TIMESTAMPTZ);` in patch-meetings-foundation.sql.
--
-- Idempotent — safe to re-run.
BEGIN;

-- ─── 1. submit_booking_request(): add p_suppress_notification ──
DROP FUNCTION IF EXISTS submit_booking_request(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID, UUID);

CREATE OR REPLACE FUNCTION submit_booking_request(
  p_room_id UUID DEFAULT NULL,
  p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_meeting_id UUID DEFAULT NULL,
  p_section_id UUID DEFAULT NULL,
  p_hold_id UUID DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_actor_org UUID;
  v_hold meeting_room_bookings;
  v_booking_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_booking_request requires an authenticated caller';
  END IF;

  IF p_hold_id IS NOT NULL THEN
    SELECT * INTO v_hold FROM meeting_room_bookings WHERE id = p_hold_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Hold not found';
    END IF;
    IF v_hold.created_by <> v_actor THEN
      RAISE EXCEPTION 'Not authorized to submit this hold';
    END IF;
    IF v_hold.status <> 'hold' THEN
      RAISE EXCEPTION 'Booking is not a hold (status: %)', v_hold.status;
    END IF;
    IF v_hold.expires_at < now() THEN
      RAISE EXCEPTION 'This hold has expired; create a new booking request';
    END IF;

    UPDATE meeting_room_bookings SET status = 'pending' WHERE id = p_hold_id;
    v_booking_id := p_hold_id;

    SELECT * INTO v_room FROM meeting_rooms WHERE id = v_hold.room_id;
  ELSE
    IF p_room_id IS NULL OR p_start_at IS NULL OR p_end_at IS NULL THEN
      RAISE EXCEPTION 'room_id, start_at, and end_at are required when not converting a hold';
    END IF;
    IF p_end_at <= p_start_at THEN
      RAISE EXCEPTION 'end_at must be after start_at';
    END IF;

    SELECT * INTO v_room FROM meeting_rooms WHERE id = p_room_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Room not found or inactive';
    END IF;
    IF NOT rooms_module_active_for(v_room.org_id) THEN
      RAISE EXCEPTION 'The Rooms module is not enabled for this organization';
    END IF;

    SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
    IF v_actor_org IS NULL THEN
      RAISE EXCEPTION 'Caller account not found or inactive';
    END IF;
    IF NOT is_super_admin() AND v_actor_org <> v_room.org_id THEN
      RAISE EXCEPTION 'Cannot book a room outside your own organization';
    END IF;

    INSERT INTO meeting_room_bookings (
      org_id, room_id, meeting_id, section_id, status,
      start_at, end_at, timezone, created_by
    ) VALUES (
      v_room.org_id, p_room_id, p_meeting_id, p_section_id, 'pending',
      p_start_at, p_end_at, p_timezone, v_actor
    ) RETURNING id INTO v_booking_id;
  END IF;

  -- Unconditional, exactly as before this patch — every individual
  -- booking submission still gets its own audit row regardless of
  -- whether its notification was suppressed (requirement 5).
  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'submitted', 'meeting_room_booking', v_booking_id);

  IF NOT p_suppress_notification THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'booking_submitted', 'meeting_room_booking', v_booking_id,
      'A new room booking request is awaiting your decision.'
    FROM room_manager_recipient_ids(v_room.id, v_actor) AS uid;
  END IF;

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. assign_room_booking(): add p_suppress_notification ──────
DROP FUNCTION IF EXISTS assign_room_booking(UUID, UUID);

CREATE OR REPLACE FUNCTION assign_room_booking(
  p_meeting_id UUID,
  p_room_id UUID,
  p_suppress_notification BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_room_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot assign a room to a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may assign a room';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to assign a room to this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF EXISTS (
    SELECT 1 FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed')
  ) THEN
    RAISE EXCEPTION 'This meeting already has an active room booking';
  END IF;

  IF is_room_manager(p_room_id, v_actor) THEN
    v_booking_id := create_room_booking(p_room_id, v_meeting.start_at, v_meeting.end_at, v_meeting.timezone, p_meeting_id);
  ELSE
    v_booking_id := submit_booking_request(
      p_room_id := p_room_id, p_start_at := v_meeting.start_at, p_end_at := v_meeting.end_at,
      p_timezone := v_meeting.timezone, p_meeting_id := p_meeting_id,
      p_suppress_notification := p_suppress_notification
    );
  END IF;

  UPDATE meetings SET location_mode = 'room' WHERE id = p_meeting_id;

  -- Unconditional, exactly as before this patch (requirement 5's
  -- same "individual records unaffected" principle applied to the
  -- meeting-side audit row too).
  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'assigned', 'meeting', p_meeting_id);

  IF NOT p_suppress_notification THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'room_assigned', 'meeting', p_meeting_id, 'A room has been assigned to a meeting you are part of.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. create_recurring_meeting(): consolidated notification ──
-- Signature is unchanged — only the body gains: (a) passing
-- p_suppress_notification := TRUE into every per-occurrence
-- assign_room_booking() call, (b) tracking the last generated
-- occurrence date, and (c) one explicit, unconditional consolidated-
-- notification step after the loop, gated only on "was a room
-- requested and does it require manager approval" — never on the
-- order booking/group calls happened to run in.
CREATE OR REPLACE FUNCTION create_recurring_meeting(
  p_title TEXT,
  p_series_start_date DATE,
  p_series_end_date DATE,
  p_start_time TIME,
  p_end_time TIME,
  p_recurrence_pattern TEXT,
  p_description TEXT DEFAULT NULL,
  p_meeting_type TEXT DEFAULT 'general',
  p_visibility TEXT DEFAULT 'participants',
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL,
  p_virtual_link TEXT DEFAULT NULL,
  p_room_id UUID DEFAULT NULL,
  p_group_id UUID DEFAULT NULL,
  p_interval_count INTEGER DEFAULT 1
) RETURNS TABLE (series_id UUID, meeting_id UUID, occurrence_date DATE) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_series_id UUID;
  v_occurrence_index INTEGER := 0;
  v_occurrence_date DATE;
  v_occurrence_start TIMESTAMPTZ;
  v_occurrence_end TIMESTAMPTZ;
  v_meeting_id UUID;
  v_occurrence_count INTEGER := 0;
  v_last_occurrence_date DATE;
  v_room_is_managed BOOLEAN;
  v_room_name TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_recurring_meeting requires an authenticated caller';
  END IF;
  IF p_recurrence_pattern NOT IN ('weekly', 'biweekly', 'monthly') THEN
    RAISE EXCEPTION 'Invalid recurrence pattern: % (expected weekly, biweekly, or monthly)', p_recurrence_pattern;
  END IF;
  IF p_interval_count < 1 THEN
    RAISE EXCEPTION 'interval_count must be at least 1';
  END IF;
  IF p_series_end_date < p_series_start_date THEN
    RAISE EXCEPTION 'series_end_date must not be before series_start_date';
  END IF;
  IF p_end_time <= p_start_time THEN
    RAISE EXCEPTION 'end_time must be after start_time';
  END IF;
  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;
  IF p_location_mode = 'external' AND p_external_location IS NULL THEN
    RAISE EXCEPTION 'external_location is required when location_mode is external';
  END IF;
  IF p_location_mode = 'virtual' AND (p_virtual_link IS NULL OR p_virtual_link !~ '^https://') THEN
    RAISE EXCEPTION 'A valid https:// virtual_link is required when location_mode is virtual';
  END IF;
  -- Occurrence-count safety cap, checked up front against the date
  -- range directly — protects against a pathological request (e.g. a
  -- multi-decade weekly series) without needing to run the loop first.
  IF (p_series_end_date - p_series_start_date) > (366 * 5) THEN
    RAISE EXCEPTION 'Recurrence range is too long (maximum 5 years)';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT meetings_module_active_for(v_actor_org) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM meeting_groups g WHERE g.id = p_group_id AND g.organization_id = v_actor_org
  ) THEN
    RAISE EXCEPTION 'This meeting group belongs to a different organization and cannot be used here';
  END IF;

  INSERT INTO meeting_series (
    organization_id, created_by, recurrence_pattern, interval_count,
    series_start_date, series_end_date,
    template_title, template_description, template_meeting_type, template_visibility,
    template_start_time, template_end_time, template_timezone,
    template_location_mode, template_external_location, template_virtual_link, template_room_id
  ) VALUES (
    v_actor_org, v_actor, p_recurrence_pattern, p_interval_count,
    p_series_start_date, p_series_end_date,
    p_title, p_description, p_meeting_type, p_visibility,
    p_start_time, p_end_time, p_timezone,
    p_location_mode, p_external_location, p_virtual_link, p_room_id
  ) RETURNING id INTO v_series_id;

  LOOP
    IF p_recurrence_pattern = 'monthly' THEN
      v_occurrence_date := (p_series_start_date + ((p_interval_count * v_occurrence_index) || ' months')::INTERVAL)::DATE;
    ELSIF p_recurrence_pattern = 'biweekly' THEN
      v_occurrence_date := p_series_start_date + (14 * p_interval_count * v_occurrence_index);
    ELSE
      v_occurrence_date := p_series_start_date + (7 * p_interval_count * v_occurrence_index);
    END IF;
    EXIT WHEN v_occurrence_date > p_series_end_date;

    v_occurrence_count := v_occurrence_count + 1;
    IF v_occurrence_count > 260 THEN
      RAISE EXCEPTION 'This recurrence would create more than 260 occurrences — narrow the date range';
    END IF;
    v_last_occurrence_date := v_occurrence_date;

    v_occurrence_start := (v_occurrence_date + p_start_time) AT TIME ZONE p_timezone;
    v_occurrence_end := (v_occurrence_date + p_end_time) AT TIME ZONE p_timezone;

    v_meeting_id := create_meeting(
      p_title := p_title, p_start_at := v_occurrence_start, p_end_at := v_occurrence_end,
      p_status := 'scheduled', p_description := p_description, p_meeting_type := p_meeting_type,
      p_visibility := p_visibility, p_timezone := p_timezone, p_location_mode := p_location_mode,
      p_external_location := p_external_location, p_virtual_link := p_virtual_link
    );

    UPDATE meetings SET series_id = v_series_id, series_occurrence_date = v_occurrence_date
      WHERE id = v_meeting_id;

    IF p_room_id IS NOT NULL THEN
      PERFORM assign_room_booking(v_meeting_id, p_room_id, p_suppress_notification := TRUE);
    END IF;
    IF p_group_id IS NOT NULL THEN
      PERFORM add_group_as_participants(v_meeting_id, p_group_id);
    END IF;

    series_id := v_series_id;
    meeting_id := v_meeting_id;
    occurrence_date := v_occurrence_date;
    RETURN NEXT;

    v_occurrence_index := v_occurrence_index + 1;
  END LOOP;

  IF v_occurrence_count = 0 THEN
    RAISE EXCEPTION 'No occurrences were generated for this date range';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'meeting_series_created', 'meeting_series', v_series_id, v_occurrence_count || ' occurrences');

  -- One notification to the creator confirming series creation — not
  -- one per occurrence, which would be spammy for a multi-month
  -- weekly series (docs/23 §Phase F/§7's explicit design). Each
  -- occurrence's own create_meeting() call fires zero notifications
  -- (matching a single ordinary meeting's own creation, which never
  -- notifies anyone either); each group member addition, if a group
  -- was supplied, fires the existing per-member participant_added
  -- notification unchanged, same as applying a group to any single
  -- ordinary meeting.
  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (v_actor, 'meeting_series_created', 'meeting_series', v_series_id,
    v_occurrence_count || ' occurrences were created for "' || p_title || '".');

  -- Consolidated room-approval notification (docs/25 §3) — fires
  -- exactly once per room manager, only when a room was requested AND
  -- that room requires approval (the creator is not one of its
  -- managers, i.e. every occurrence went through submit_booking_
  -- request(), never create_room_booking()'s auto-confirm path, which
  -- never notified anyone in the first place — matching that existing
  -- behavior exactly, just applied once instead of never). Computed
  -- explicitly here, not inferred from whether a per-occurrence
  -- notification happened to fire.
  IF p_room_id IS NOT NULL THEN
    v_room_is_managed := is_room_manager(p_room_id, v_actor);
    IF NOT v_room_is_managed THEN
      SELECT name INTO v_room_name FROM meeting_rooms WHERE id = p_room_id;
      INSERT INTO notifications (user_id, type, record_type, record_id, message)
      SELECT uid, 'recurring_booking_submitted', 'meeting_series', v_series_id,
        'Recurring series "' || p_title || '" (ID ' || v_series_id || ') has ' || v_occurrence_count ||
        ' pending room-booking request' || (CASE WHEN v_occurrence_count = 1 THEN '' ELSE 's' END) ||
        ' for "' || COALESCE(v_room_name, 'this room') || '" awaiting your decision — occurrences from ' ||
        p_series_start_date || ' to ' || v_last_occurrence_date || '.'
      FROM room_manager_recipient_ids(p_room_id, v_actor) AS uid;
    END IF;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. notifications.type CHECK extension ───────────────────────
-- Full accumulated list restated (per docs/23 §0's coordination
-- note), not a bare addition.
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
    'recurring_booking_submitted'
  ));

COMMIT;
