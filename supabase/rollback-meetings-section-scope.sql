-- ============================================================
-- CorLink — Rollback: section-scoped meeting access control
-- (undoes supabase/patch-meetings-section-scope.sql)
--
-- Restores can_manage_meeting()/can_view_meeting()/create_meeting()/
-- update_meeting()/create_recurring_meeting() to their exact pre-patch
-- bodies (the blanket is_supervisor_or_above() term, no p_section_id
-- param), then drops meetings.section_id and
-- meeting_series.template_section_id.
--
-- Refuses unconditionally if any meeting or series has a non-NULL
-- section_id/template_section_id — once real meetings have been
-- explicitly tagged to a section (whether for this access-control
-- feature or just as an "on behalf of" label), dropping the column
-- would silently destroy that data. This mirrors the "refuse if real
-- work exists" precedent already used elsewhere in this codebase
-- (see docs/rollback/017) rather than a permissive rollback.
--
-- Idempotent to run against a database already rolled back (the
-- refusal checks simply find nothing and the DROP COLUMN IF EXISTS/
-- function bodies are safe to reapply).
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM meetings WHERE section_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one meeting has section_id set — this data would be destroyed. Clear it first if you are certain, or keep this patch applied.';
  END IF;
  IF EXISTS (SELECT 1 FROM meeting_series WHERE template_section_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one recurring series has template_section_id set — this data would be destroyed. Clear it first if you are certain, or keep this patch applied.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION can_manage_meeting(p_meeting_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
        m.created_by = auth.uid()
        OR (m.organization_id = get_my_org_id() AND is_supervisor_or_above())
      )
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

CREATE OR REPLACE FUNCTION can_view_meeting(p_meeting_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
        m.created_by = auth.uid()
        OR EXISTS (
          SELECT 1 FROM meeting_participants mp
          WHERE mp.meeting_id = m.id AND mp.user_id = auth.uid() AND mp.removed_at IS NULL
        )
        OR (m.organization_id = get_my_org_id() AND is_supervisor_or_above())
        OR (m.visibility = 'organization' AND m.organization_id = get_my_org_id()
            AND current_user_module_enabled('meetings'))
      )
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

CREATE OR REPLACE FUNCTION create_meeting(
  p_title TEXT, p_start_at TIMESTAMPTZ, p_end_at TIMESTAMPTZ, p_status TEXT DEFAULT 'scheduled',
  p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT 'general', p_visibility TEXT DEFAULT 'participants',
  p_timezone TEXT DEFAULT 'Indian/Maldives', p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_meeting_id UUID;
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

  INSERT INTO meetings (
    organization_id, created_by, title, description, meeting_type, status, visibility,
    timezone, start_at, end_at, location_mode, external_location, virtual_link
  ) VALUES (
    v_actor_org, v_actor, p_title, p_description, p_meeting_type, p_status, p_visibility,
    p_timezone, p_start_at, p_end_at, p_location_mode, p_external_location, p_virtual_link
  ) RETURNING id INTO v_meeting_id;

  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invitation_status, is_organizer, invited_by)
  VALUES (v_meeting_id, v_actor, 'organizer', 'accepted', TRUE, v_actor);

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting', v_meeting_id);

  RETURN v_meeting_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

CREATE OR REPLACE FUNCTION update_meeting(
  p_meeting_id UUID, p_title TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL, p_status TEXT DEFAULT NULL, p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL, p_timezone TEXT DEFAULT NULL, p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL, p_suppress_notification BOOLEAN DEFAULT FALSE,
  p_preserve_series_membership BOOLEAN DEFAULT FALSE
)
RETURNS VOID AS $$
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
  v_audit_id UUID;
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
  VALUES (v_actor, 'edited', 'meeting', p_meeting_id)
  RETURNING id INTO v_audit_id;

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

  IF NOT p_suppress_notification AND v_time_changed AND NOT v_publishing AND v_new_status = 'scheduled' THEN
    PERFORM platform_enqueue_outbox_event(
      'meetings.rescheduled.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.rescheduled.v1',
        'title_template_key', 'meetings.rescheduled',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', COALESCE(p_title, v_meeting.title),
          'new_start_at', v_new_start, 'new_end_at', v_new_end, 'rescheduled_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'meeting_participants',
        'target_meeting_id', p_meeting_id
      ),
      v_audit_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

CREATE OR REPLACE FUNCTION create_recurring_meeting(
  p_title TEXT, p_series_start_date DATE, p_series_end_date DATE, p_start_time TIME, p_end_time TIME,
  p_recurrence_pattern TEXT, p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT 'general',
  p_visibility TEXT DEFAULT 'participants', p_timezone TEXT DEFAULT 'Indian/Maldives', p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL, p_room_id UUID DEFAULT NULL,
  p_group_id UUID DEFAULT NULL, p_interval_count INTEGER DEFAULT 1
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

ALTER TABLE meetings DROP COLUMN IF EXISTS section_id;
ALTER TABLE meeting_series DROP COLUMN IF EXISTS template_section_id;

COMMIT;
