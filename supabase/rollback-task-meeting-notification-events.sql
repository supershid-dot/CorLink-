-- CAP-003 Phase 1.4B rollback. Restores complete_task()/
-- update_meeting()/cancel_meeting() to their exact, byte-for-byte
-- pre-1.4B bodies (verified via pg_get_functiondef() equality against
-- a baseline built with patch-task-meeting-notification-events.sql
-- excluded from the loop), removes the 3 event-type registry rows this
-- milestone added, and refuses (raises, never silently discards
-- evidence) if any persisted platform_outbox_events/user_notifications
-- row still uses one of the 3 event types. Preserves every Phase
-- 1.4/1.4A object (task.assigned.v1, task_watchers, meeting_participants,
-- intent_user_can_view_task/meeting) completely untouched.
BEGIN;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type IN ('task.completed.v1', 'meetings.rescheduled.v1', 'meetings.cancelled.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % platform_outbox_events row(s) use one of the three Phase 1.4B event types. Restoring the pre-1.4B function bodies would strand this evidence (docs/78 Sec19 -- immutable business evidence, never silently discarded). Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type IN ('task.completed.v1', 'meetings.rescheduled.v1', 'meetings.cancelled.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % user_notifications row(s) use one of the three Phase 1.4B event types. Restoring the pre-1.4B function bodies would strand this evidence. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
END $$;

-- ─── 1. complete_task(): restore to the exact pre-1.4B body
-- (patch-task-dependency-lifecycle-enforcement.sql's own version --
-- no legacy-audit-id capture, no atomic outbox enqueue). ────────────
CREATE OR REPLACE FUNCTION complete_task(p_task_id UUID, p_notes TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_dependency_state RECORD;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'complete_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to complete this task';
  END IF;
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_task.organization_id::TEXT, 0)
  );
  SELECT * INTO v_task FROM tasks WHERE id = p_task_id FOR UPDATE;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to complete this task';
  END IF;
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  SELECT * INTO v_dependency_state FROM get_task_dependency_state(p_task_id);
  IF v_dependency_state.is_blocked THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'Task cannot be completed because one or more prerequisites are unresolved.';
  END IF;

  UPDATE tasks
  SET status = 'completed', completed_at = NOW(), completed_by = v_actor
  WHERE id = p_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'completed', 'task', p_task_id, p_notes);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'task_completed', 'task', p_task_id,
         'Task "' || v_task.title || '" was marked completed'
  FROM (
    SELECT v_task.created_by AS uid
    UNION
    SELECT user_id FROM task_watchers WHERE task_id = p_task_id
  ) recipients
  WHERE uid IS NOT NULL AND uid <> v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. update_meeting(): restore to the exact pre-1.4B body
-- (patch-meetings-recurring-phase2-preserve-series-membership.sql's
-- own 14-parameter version -- no audit-id capture, no
-- meetings.rescheduled.v1 enqueue). ─────────────────────────────────
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

-- ─── 3. cancel_meeting(): restore to the exact pre-1.4B body
-- (patch-meetings-recurring-phase2-notification-suppression.sql's own
-- 3-parameter version -- no audit-id capture, no
-- meetings.cancelled.v1 enqueue). ───────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_meeting(
  p_meeting_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Meeting is already cancelled';
  END IF;
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot cancel a draft meeting — delete it instead using delete_draft_meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may cancel it';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to cancel this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF v_actor <> v_meeting.created_by AND (p_cancellation_reason IS NULL OR btrim(p_cancellation_reason) = '') THEN
    RAISE EXCEPTION 'A cancellation reason is required';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
  IF FOUND THEN
    UPDATE meeting_room_bookings SET
      status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
      cancellation_reason = COALESCE(p_cancellation_reason, 'Meeting cancelled')
      WHERE id = v_booking.id;

    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
    VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, p_cancellation_reason);
  END IF;

  UPDATE meetings SET
    status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
    cancellation_reason = p_cancellation_reason
    WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting', p_meeting_id, p_cancellation_reason);

  IF NOT p_suppress_notification THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_cancelled', 'meeting', p_meeting_id, 'A meeting you are part of has been cancelled.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Remove the 3 Phase 1.4B registry rows only ─────────────────
DELETE FROM platform_event_type_registry
WHERE event_type IN ('task.completed.v1', 'meetings.rescheduled.v1', 'meetings.cancelled.v1');

COMMIT;
