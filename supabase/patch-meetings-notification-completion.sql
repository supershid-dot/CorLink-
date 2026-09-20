-- ============================================================
-- CorLink — Patch: Meetings notification completion
--   (scheduled / updated events, a reminder mechanism, and a
--   Telegram delivery channel — feature parity with MeetFlow)
--
-- CAP-003's meetings.rescheduled.v1 and meetings.cancelled.v1
-- (patch-task-meeting-notification-events.sql) already cover two of
-- the five events MeetFlow sends. This patch adds the other two
-- (meetings.scheduled.v1, meetings.updated.v1) and an entirely new
-- mechanism this codebase never had at all: a reminder fired shortly
-- before a meeting starts (meetings.reminder.v1). Every event still
-- goes through the exact same generic outbox pipeline
-- (platform_enqueue_outbox_event -> user_notifications) the existing
-- two events already use — no worker/target-kind changes needed,
-- since 'meeting' + 'meeting_participants' are already fully wired.
--
-- Scope decisions (see the accompanying plan for the full reasoning):
--   * meetings.scheduled.v1 fires once, either from create_meeting()
--     directly (status='scheduled' at creation) or from
--     update_meeting()'s existing v_publishing branch (draft ->
--     scheduled) -- whichever happens first for a given meeting.
--   * meetings.updated.v1 fires only for a genuine NON-time edit of an
--     already-scheduled meeting, narrowly excluding the case already
--     covered by meetings.rescheduled.v1 -- a single edit never fires
--     both.
--   * create_meeting() gains a new p_suppress_notification flag
--     (mirroring update_meeting/cancel_meeting's existing one) so
--     create_recurring_meeting()'s internal per-occurrence
--     create_meeting() calls (up to 260 of them for one series) don't
--     spam one meetings.scheduled.v1 per occurrence -- series creation
--     keeps its existing single consolidated legacy notification. The
--     reminder schedule (reminder_at) is set regardless of this flag;
--     every occurrence still needs its own "starting soon" ping.
--   * update_entire_series/update_series_this_and_future/
--     cancel_entire_series/cancel_series_this_and_future all already
--     PERFORM update_meeting()/cancel_meeting() per affected
--     occurrence with p_suppress_notification := TRUE -- since the new
--     events and reminder-column maintenance live inside those two
--     base functions, every series bulk-op cascades correctly with NO
--     changes needed to any of those four files.
--   * No legacy `notifications` row for any of the three new event
--     types -- unlike rescheduled/cancelled (which had a legacy
--     sibling before CAP-003 existed), these are brand-new
--     notifications with no prior behavior to dual-write against.
--
-- Idempotent -- ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / ON
-- CONFLICT DO NOTHING throughout, matching this repo's convention.
-- ============================================================

BEGIN;

-- ─── 1. New columns ─────────────────────────────────────────────
-- reminder_at/reminder_dispatched_at: maintained by create_meeting()/
-- update_meeting() below, consumed by dispatch_due_meeting_reminders()
-- (this patch, further down). telegram_chat_id: admin-entered on the
-- Admin > Manage User screen (js/views/admin.js), read by the new
-- process-meeting-notifications Edge Function -- never by any SQL
-- function in this patch. telegram_sent_at: written only by that same
-- Edge Function (via its service-role client, bypassing RLS the same
-- way create-user/reset-password already do) -- not one of the columns
-- user_notifications_enforce_immutability() lists as immutable, so no
-- trigger change is needed for it to become freely settable once.
ALTER TABLE meetings           ADD COLUMN IF NOT EXISTS reminder_at TIMESTAMPTZ;
ALTER TABLE meetings           ADD COLUMN IF NOT EXISTS reminder_dispatched_at TIMESTAMPTZ;
ALTER TABLE users               ADD COLUMN IF NOT EXISTS telegram_chat_id TEXT;
ALTER TABLE user_notifications ADD COLUMN IF NOT EXISTS telegram_sent_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_meetings_reminder_due
  ON meetings(reminder_at)
  WHERE reminder_at IS NOT NULL AND reminder_dispatched_at IS NULL;

-- ─── 2. Register the three new event types ─────────────────────
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'meetings.scheduled.v1', 'meetings', FALSE, FALSE,
    'A meeting became scheduled -- either created directly with status=scheduled (create_meeting()) or published from draft (update_meeting()''s v_publishing branch). Fires at most once per meeting. Recipients: meeting_participants target kind. Respects p_suppress_notification (set by create_recurring_meeting() per occurrence, so a series create sends one consolidated legacy notification instead of one CAP-003 event per occurrence).',
    TRUE
  ),
  (
    'meetings.updated.v1', 'meetings', FALSE, FALSE,
    'An already-scheduled meeting had a genuine non-time change (title/location/etc. -- update_meeting()), narrowly excluding any edit meetings.rescheduled.v1 already covers, so a single edit never fires both. Recipients: meeting_participants target kind. Respects the existing p_suppress_notification flag.',
    TRUE
  ),
  (
    'meetings.reminder.v1', 'meetings', FALSE, FALSE,
    'A scheduled meeting is starting soon (30 minutes by default -- see reminder_at, maintained by create_meeting()/update_meeting()). Dispatched by dispatch_due_meeting_reminders(), an authenticated-caller-callable RPC any open client tab polls periodically (this codebase has no cron/timer infrastructure of any kind; see docs/16 and docs/83). Recipients: meeting_participants target kind. Marked once via reminder_dispatched_at so no client poll can double-fire it.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 3. create_meeting(): reminder scheduling + meetings.scheduled.v1
-- True latest body (patch-meetings-section-scope.sql, confirmed the
-- sole/final redefinition) reproduced verbatim, with ONLY these
-- additions: the new trailing p_suppress_notification parameter, a
-- RETURNING id on the existing audit_logs insert (for the outbox
-- idempotency key), and the reminder/outbox block after it. ────────
DROP FUNCTION IF EXISTS create_meeting(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID);

CREATE OR REPLACE FUNCTION create_meeting(
  p_title TEXT, p_start_at TIMESTAMPTZ, p_end_at TIMESTAMPTZ, p_status TEXT DEFAULT 'scheduled',
  p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT 'general', p_visibility TEXT DEFAULT 'participants',
  p_timezone TEXT DEFAULT 'Indian/Maldives', p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL, p_section_id UUID DEFAULT NULL,
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

  -- Reminder scheduling and the meetings.scheduled.v1 event are
  -- independent: every scheduled meeting gets a reminder (even a
  -- suppressed per-occurrence series create), but the notification
  -- itself respects p_suppress_notification (see this patch's header).
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

-- ─── 4. update_meeting(): reminder maintenance + meetings.scheduled.v1
-- (on publish) / meetings.updated.v1 (on a genuine non-time edit) ──
-- True latest body (patch-meetings-section-scope.sql, the version with
-- p_section_id/p_clear_section -- confirmed the sole/final
-- redefinition) reproduced verbatim. No parameter changes, so no DROP
-- is needed. Only additions: reminder_at maintenance in the existing
-- UPDATE meetings SET ... statement, and a new enqueue block sibling
-- to the existing meetings.rescheduled.v1 one. ─────────────────────
CREATE OR REPLACE FUNCTION update_meeting(
  p_meeting_id UUID, p_title TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL, p_status TEXT DEFAULT NULL, p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL, p_timezone TEXT DEFAULT NULL, p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL, p_suppress_notification BOOLEAN DEFAULT FALSE,
  p_preserve_series_membership BOOLEAN DEFAULT FALSE, p_section_id UUID DEFAULT NULL, p_clear_section BOOLEAN DEFAULT FALSE
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
  v_new_section_id UUID;
  v_audit_id UUID;
  v_new_reminder_at TIMESTAMPTZ;
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

  v_new_section_id := CASE WHEN p_clear_section THEN NULL WHEN p_section_id IS NOT NULL THEN p_section_id ELSE v_meeting.section_id END;
  IF v_new_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections s WHERE s.id = v_new_section_id AND s.org_id = v_meeting.organization_id
  ) THEN
    RAISE EXCEPTION 'This section belongs to a different organization and cannot be used here';
  END IF;

  v_meaningful_change := (
    p_title IS NOT NULL OR v_time_changed OR p_location_mode IS NOT NULL
    OR p_external_location IS NOT NULL OR p_virtual_link IS NOT NULL
  );

  -- Reminder recompute: a genuine time change always shifts it; first
  -- publish (draft -> scheduled) sets one even without a time change,
  -- since a draft never had one (create_meeting() only sets reminder_at
  -- for a meeting created directly as 'scheduled'). Left unchanged in
  -- every other case. NULLed out if the new start has already passed
  -- (e.g. a very late edit) -- no point queuing a reminder for the past.
  v_new_reminder_at := v_meeting.reminder_at;
  IF v_time_changed OR v_publishing THEN
    IF v_new_status = 'scheduled' AND v_new_start > NOW() THEN
      v_new_reminder_at := v_new_start - INTERVAL '30 minutes';
    ELSE
      v_new_reminder_at := NULL;
    END IF;
  END IF;

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
    section_id = v_new_section_id,
    reminder_at = v_new_reminder_at,
    reminder_dispatched_at = CASE WHEN v_new_reminder_at IS DISTINCT FROM v_meeting.reminder_at THEN NULL ELSE reminder_dispatched_at END,
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

  -- CAP-003 Phase 1.4B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Narrowly scoped to a genuine reschedule of
  -- an already-scheduled meeting -- never on first publish (v_publishing
  -- is a "scheduled" event, deferred, not "rescheduled"), never on a
  -- title/location-only edit with no time change, never when the
  -- caller has suppressed notifications (bulk recurring-series safety).
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

  -- This patch: meetings.scheduled.v1 on first publish (mirrors
  -- create_meeting()'s own direct-create case above -- together the
  -- two cover "a meeting became scheduled" exactly once, however it
  -- happened), OR meetings.updated.v1 for a genuine non-time edit of
  -- an already-scheduled meeting. Mutually exclusive with each other
  -- AND with meetings.rescheduled.v1 immediately above (NOT
  -- v_time_changed here is what keeps a plain reschedule from also
  -- firing "updated").
  IF NOT p_suppress_notification AND v_publishing THEN
    PERFORM platform_enqueue_outbox_event(
      'meetings.scheduled.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.scheduled.v1',
        'title_template_key', 'meetings.scheduled',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', COALESCE(p_title, v_meeting.title),
          'start_at', v_new_start, 'scheduled_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'meeting_participants',
        'target_meeting_id', p_meeting_id
      ),
      v_audit_id
    );
  ELSIF NOT p_suppress_notification AND v_meaningful_change AND NOT v_time_changed AND v_new_status = 'scheduled' THEN
    PERFORM platform_enqueue_outbox_event(
      'meetings.updated.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.updated.v1',
        'title_template_key', 'meetings.updated',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', COALESCE(p_title, v_meeting.title), 'updated_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'meeting_participants',
        'target_meeting_id', p_meeting_id
      ),
      v_audit_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. create_recurring_meeting(): suppress per-occurrence
-- meetings.scheduled.v1 (series creation keeps its existing single
-- consolidated legacy notification instead) -- reminder_at is still
-- set for every occurrence since create_meeting() sets it whenever
-- p_status='scheduled', independent of p_suppress_notification. ────
-- True latest body (patch-meetings-section-scope.sql) reproduced
-- verbatim; only the create_meeting() call gains
-- p_suppress_notification := TRUE.
CREATE OR REPLACE FUNCTION create_recurring_meeting(
  p_title TEXT, p_series_start_date DATE, p_series_end_date DATE, p_start_time TIME, p_end_time TIME,
  p_recurrence_pattern TEXT, p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT 'general',
  p_visibility TEXT DEFAULT 'participants', p_timezone TEXT DEFAULT 'Indian/Maldives', p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL, p_room_id UUID DEFAULT NULL,
  p_group_id UUID DEFAULT NULL, p_interval_count INTEGER DEFAULT 1, p_section_id UUID DEFAULT NULL
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp';

-- ─── 6. dispatch_due_meeting_reminders(): the client-poll entry point
-- Any authenticated user may call this (system-wide sweep, not scoped
-- to the caller's own org/meetings -- same non-scoped-utility shape as
-- check_deadlines(), supabase/notifications.sql, this codebase's only
-- other "find everything due right now" function). The UPDATE ...
-- WHERE reminder_dispatched_at IS NULL ... RETURNING is what makes
-- concurrent polls from multiple open tabs safe: row-level locking
-- means only one caller ever observes a given due meeting, so
-- platform_enqueue_outbox_event()'s own idempotency check (same key =>
-- must be same payload, else it raises) is a backstop here, never the
-- primary safety mechanism. A meeting that was cancelled after its
-- reminder was queued is naturally excluded by the status='scheduled'
-- filter -- cancel_meeting() does not need to clear reminder_at itself.
CREATE OR REPLACE FUNCTION dispatch_due_meeting_reminders()
RETURNS SETOF UUID AS $$
DECLARE
  v_row RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'dispatch_due_meeting_reminders requires an authenticated caller';
  END IF;

  FOR v_row IN
    UPDATE meetings SET reminder_dispatched_at = NOW()
    WHERE reminder_at IS NOT NULL AND reminder_at <= NOW()
      AND reminder_dispatched_at IS NULL AND status = 'scheduled'
    RETURNING id, organization_id, title, start_at, created_by
  LOOP
    PERFORM platform_enqueue_outbox_event(
      'meetings.reminder.v1', 'meetings', 'meeting', v_row.id, v_row.organization_id, v_row.created_by,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.reminder.v1',
        'title_template_key', 'meetings.reminder',
        'template_params', jsonb_build_object(
          'meeting_id', v_row.id, 'meeting_title', v_row.title, 'start_at', v_row.start_at
        ),
        'priority', 'high',
        'target_type', 'meeting_participants',
        'target_meeting_id', v_row.id
      ),
      md5(v_row.id::TEXT || ':reminder')::UUID
    );
    RETURN NEXT v_row.id;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- REVOKE from PUBLIC/anon, GRANT EXECUTE only to authenticated —
-- matching Entry/Internal Collaboration's own established grant
-- convention. auth.uid() is what the function's own auth check relies
-- on, and an anon-key caller has no such claim (auth.uid() resolves
-- to NULL for them regardless), so the RAISE EXCEPTION inside the
-- function already made an anon call harmless in practice — this is
-- the explicit, intentional version of that same posture rather than
-- leaning on the function body alone.
REVOKE ALL ON FUNCTION dispatch_due_meeting_reminders() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION dispatch_due_meeting_reminders() TO authenticated;

COMMIT;
