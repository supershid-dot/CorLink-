-- 155: "Pre-book Meeting Slots" (MeetFlow parity, admin-only).
--
-- UAT: "pre book meeting rooms needs to be added to the corlink like in
-- meetflow, this access is given to only admins of the system" — a
-- MeetFlow screenshot of its "Pre-book Meeting Slots" modal (title,
-- section, optional room, from/to date, day-of-week checkboxes,
-- start/end time) — "Creates placeholder bookings for a section.
-- Section staff can later open each slot to complete the full
-- details."
--
-- meetings.status already has a 'draft' value (patch-meetings-
-- foundation.sql), already fully editable, and already visible via RLS
-- to a section's own members through can_view_meeting()'s
-- `m.section_id IN (SELECT my_section_ids())` branch (patch-meetings-
-- section-scope.sql) — so a placeholder slot is simply a draft meeting
-- tagged to a section with no participants yet. What's missing is a
-- bulk day-of-week x date-range creation RPC (create_recurring_meeting
-- only does weekly/biweekly/monthly single-day patterns and always
-- creates status='scheduled', never 'draft').
--
-- create_prebooked_meeting_slots() mirrors create_recurring_meeting()'s
-- own structure (patch-meetings-organizer-designation.sql: validate ->
-- loop dates -> create_meeting() per occurrence -> optional
-- assign_room_booking() -> one audit row) — a new, purpose-built RPC
-- rather than retrofitting create_recurring_meeting() itself, since
-- that function's signature/notification behavior (always 'scheduled',
-- single-weekday-per-week patterns) is different enough that
-- shoehorning "draft, multiple weekdays per week" into it would be a
-- riskier change to a working, heavily-used function.
--
-- All-or-nothing on conflict: one RPC call is one implicit Postgres
-- transaction, so a room-booking conflict on ANY generated slot
-- (raised by meeting_room_bookings_no_overlap inside
-- assign_room_booking -> create_room_booking) rolls back every slot
-- already inserted in this call — same behavior
-- create_recurring_meeting() already has, no special-case code needed.
--
-- No new notification event for slot creation — MeetFlow's own
-- screenshots show no such notification either, and create_meeting()'s
-- notification block is gated on p_status = 'scheduled' anyway (a
-- draft never notifies regardless), so p_suppress_notification := TRUE
-- below is belt-and-suspenders, matching create_recurring_meeting()'s
-- own style.

CREATE OR REPLACE FUNCTION create_prebooked_meeting_slots(
  p_title TEXT,
  p_section_id UUID,
  p_from_date DATE,
  p_to_date DATE,
  p_days_of_week INTEGER[],   -- 0=Sunday..6=Saturday (matches EXTRACT(DOW) and JS Date.getDay())
  p_start_time TIME,
  p_end_time TIME,
  p_room_id UUID DEFAULT NULL,
  p_timezone TEXT DEFAULT 'Indian/Maldives'
)
RETURNS TABLE(meeting_id UUID, slot_date DATE) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_d DATE;
  v_slot_start TIMESTAMPTZ;
  v_slot_end TIMESTAMPTZ;
  v_meeting_id UUID;
  v_slot_count INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prebooked_meeting_slots requires an authenticated caller';
  END IF;
  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;
  IF p_to_date < p_from_date THEN
    RAISE EXCEPTION 'to_date must not be before from_date';
  END IF;
  IF (p_to_date - p_from_date) > 366 THEN
    RAISE EXCEPTION 'Date range is too long (maximum 1 year)';
  END IF;
  IF p_end_time <= p_start_time THEN
    RAISE EXCEPTION 'end_time must be after start_time';
  END IF;
  IF p_days_of_week IS NULL OR array_length(p_days_of_week, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one day of the week';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_days_of_week) d WHERE d < 0 OR d > 6) THEN
    RAISE EXCEPTION 'Invalid day-of-week value (expected 0-6)';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT (is_super_admin() OR (is_admin() AND v_actor_org = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to pre-book meeting slots';
  END IF;
  IF NOT meetings_module_active_for(v_actor_org) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM sections s WHERE s.id = p_section_id AND s.org_id = v_actor_org) THEN
    RAISE EXCEPTION 'This section belongs to a different organization and cannot be used here';
  END IF;

  v_d := p_from_date;
  WHILE v_d <= p_to_date LOOP
    IF EXTRACT(DOW FROM v_d)::INTEGER = ANY(p_days_of_week) THEN
      v_slot_count := v_slot_count + 1;
      IF v_slot_count > 260 THEN
        RAISE EXCEPTION 'This would create more than 260 slots — narrow the date range or days selected';
      END IF;

      v_slot_start := (v_d + p_start_time) AT TIME ZONE p_timezone;
      v_slot_end := (v_d + p_end_time) AT TIME ZONE p_timezone;

      v_meeting_id := create_meeting(
        p_title := p_title, p_start_at := v_slot_start, p_end_at := v_slot_end,
        p_status := 'draft', p_meeting_type := 'general', p_visibility := 'participants',
        p_timezone := p_timezone, p_section_id := p_section_id,
        p_suppress_notification := TRUE, p_include_creator_as_participant := FALSE
      );

      IF p_room_id IS NOT NULL THEN
        PERFORM assign_room_booking(v_meeting_id, p_room_id, p_suppress_notification := TRUE);
      END IF;

      meeting_id := v_meeting_id;
      slot_date := v_d;
      RETURN NEXT;
    END IF;
    v_d := v_d + 1;
  END LOOP;

  IF v_slot_count = 0 THEN
    RAISE EXCEPTION 'No slots were generated for the selected date range and days of week';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'meeting_prebook_slots_created', 'section', p_section_id, v_slot_count || ' slots for "' || p_title || '"');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION create_prebooked_meeting_slots(TEXT, UUID, DATE, DATE, INTEGER[], TIME, TIME, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_prebooked_meeting_slots(TEXT, UUID, DATE, DATE, INTEGER[], TIME, TIME, UUID, TEXT) TO authenticated;

-- Audit action vocabulary: adds 'meeting_prebook_slots_created', the
-- one new action this migration's own audit_logs insert writes. True
-- current latest predecessor: patch-meetings-notify-participants.sql
-- (adding 'meeting_notification_sent') — the most recent file to touch
-- audit_logs_action_check. Every previously-allowed value is preserved
-- verbatim.
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned', 'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden', 'unassigned',
    'participant_added', 'participant_removed', 'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked', 'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked', 'meeting_group_created', 'meeting_group_updated',
    'meeting_group_deleted', 'meeting_group_members_updated', 'meeting_series_created',
    'meeting_draft_deleted', 'meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled',
    'completed', 'commented', 'task_linked', 'task_unlinked',
    'task_dependency_added', 'task_dependency_removed', 'task_dependency_waived',
    'task_started', 'task_work_started',
    'task_relationship_added', 'task_relationship_removed',
    'module_enabled', 'module_disabled',
    'meeting_notification_sent',
    'meeting_prebook_slots_created'
  ));
