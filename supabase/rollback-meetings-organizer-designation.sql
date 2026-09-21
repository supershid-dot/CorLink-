-- Rollback for patch-meetings-organizer-designation.sql (136).
-- Restores create_meeting() / create_recurring_meeting() to their
-- pre-136 bodies (supabase/patch-meetings-notification-completion.sql)
-- — drops the p_include_creator_as_participant parameter entirely and
-- restores the unconditional creator-as-organizer insert.
--
-- Each function's 136 signature is DROPped explicitly first — CREATE
-- OR REPLACE cannot change a function's parameter list, it would just
-- create a second overload alongside the 136 one (same reasoning every
-- other rollback script in this repo gives for a trailing-param patch).

DROP FUNCTION IF EXISTS create_meeting(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION create_meeting(
  p_title TEXT,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_status TEXT DEFAULT 'scheduled',
  p_description TEXT DEFAULT NULL,
  p_meeting_type TEXT DEFAULT 'general',
  p_visibility TEXT DEFAULT 'participants',
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL,
  p_virtual_link TEXT DEFAULT NULL,
  p_section_id UUID DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE
)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_meeting_id UUID;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_meeting requires an authenticated caller';
  END IF;
  IF p_status NOT IN ('draft', 'scheduled') THEN
    RAISE EXCEPTION 'Invalid status for create_meeting: %', p_status;
  END IF;
  IF p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'end_at must be after start_at';
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

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT meetings_module_active_for(v_actor_org) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF p_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections s WHERE s.id = p_section_id AND s.org_id = v_actor_org
  ) THEN
    RAISE EXCEPTION 'This section belongs to a different organization and cannot be used here';
  END IF;

  INSERT INTO meetings (
    organization_id, created_by, title, description, meeting_type, status, visibility,
    timezone, start_at, end_at, location_mode, external_location, virtual_link, section_id
  ) VALUES (
    v_actor_org, v_actor, p_title, p_description, p_meeting_type, p_status, p_visibility,
    p_timezone, p_start_at, p_end_at, p_location_mode, p_external_location, p_virtual_link, p_section_id
  ) RETURNING id INTO v_meeting_id;

  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invitation_status, is_organizer, invited_by)
  VALUES (v_meeting_id, v_actor, 'organizer', 'accepted', TRUE, v_actor);

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting', v_meeting_id)
  RETURNING id INTO v_audit_id;

  IF p_status = 'scheduled' THEN
    IF p_start_at > NOW() THEN
      UPDATE meetings SET reminder_at = p_start_at - INTERVAL '30 minutes' WHERE id = v_meeting_id;
    END IF;

    IF NOT p_suppress_notification THEN
      PERFORM platform_enqueue_outbox_event(
        'meetings.scheduled.v1', 'meetings', 'meeting', v_meeting_id, v_actor_org, v_actor,
        gen_random_uuid(), NULL, NOW(),
        jsonb_build_object(
          'notification_type', 'meetings.scheduled.v1',
          'title_template_key', 'meetings.scheduled',
          'template_params', jsonb_build_object(
            'meeting_id', v_meeting_id, 'meeting_title', p_title, 'start_at', p_start_at, 'scheduled_by', v_actor
          ),
          'priority', 'normal',
          'target_type', 'meeting_participants',
          'target_meeting_id', v_meeting_id
        ),
        v_audit_id
      );
    END IF;
  END IF;

  RETURN v_meeting_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP FUNCTION IF EXISTS create_recurring_meeting(TEXT, DATE, DATE, TIME, TIME, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID, INTEGER, UUID, BOOLEAN);

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
  p_interval_count INTEGER DEFAULT 1,
  p_section_id UUID DEFAULT NULL
)
RETURNS TABLE(series_id UUID, meeting_id UUID, occurrence_date DATE) AS $$
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
  IF p_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections s WHERE s.id = p_section_id AND s.org_id = v_actor_org
  ) THEN
    RAISE EXCEPTION 'This section belongs to a different organization and cannot be used here';
  END IF;

  INSERT INTO meeting_series (
    organization_id, created_by, recurrence_pattern, interval_count,
    series_start_date, series_end_date,
    template_title, template_description, template_meeting_type, template_visibility,
    template_start_time, template_end_time, template_timezone,
    template_location_mode, template_external_location, template_virtual_link, template_room_id,
    template_section_id
  ) VALUES (
    v_actor_org, v_actor, p_recurrence_pattern, p_interval_count,
    p_series_start_date, p_series_end_date,
    p_title, p_description, p_meeting_type, p_visibility,
    p_start_time, p_end_time, p_timezone,
    p_location_mode, p_external_location, p_virtual_link, p_room_id,
    p_section_id
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
      p_external_location := p_external_location, p_virtual_link := p_virtual_link, p_section_id := p_section_id,
      p_suppress_notification := TRUE
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

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (v_actor, 'meeting_series_created', 'meeting_series', v_series_id,
    v_occurrence_count || ' occurrences were created for "' || p_title || '".');

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
