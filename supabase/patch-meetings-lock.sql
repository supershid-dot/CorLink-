-- ─── Patch: Meeting Locking (docs/22 Phase B, docs/23 §Phase B) ────
-- Requires patch-meetings-foundation.sql, patch-meetings-rsvp.sql,
-- patch-meetings-attendance.sql, and patch-meetings-minutes.sql
-- already applied. Implements only the meeting-lock portion of
-- docs/23's Phase B specification — deliberately does NOT touch
-- personal participant notes (meeting_participants.personal_notes
-- does not exist after this patch). Approved override tiers: the
-- meeting's creator can always lock/unlock their own meeting; an
-- organization administrator can override (unlock) a lock within
-- their own organization only; a super administrator can override
-- (unlock) any lock anywhere; supervisors, room managers, and
-- ordinary staff can never override a lock. Idempotent — safe to
-- re-run.
BEGIN;

-- ─── 1. meetings: lock columns ──────────────────────────────────
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS is_locked BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS locked_by UUID REFERENCES users(id);
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS locked_at TIMESTAMPTZ;

-- Bidirectional, same convention as meetings_cancel_alignment_check
-- and meetings_minutes_finalized_requires_minutes_check already in
-- this table — stronger than docs/23's literal
-- "(is_locked = FALSE OR locked_by IS NOT NULL)" (which this implies)
-- by also requiring locked_at to stay in lockstep with locked_by.
ALTER TABLE meetings DROP CONSTRAINT IF EXISTS meetings_lock_alignment_check;
ALTER TABLE meetings ADD CONSTRAINT meetings_lock_alignment_check
  CHECK ((is_locked = TRUE) = (locked_by IS NOT NULL AND locked_at IS NOT NULL));

-- ─── 2. is_meeting_lock_overridable() helper ────────────────────
-- docs/23 §Phase B/§4's exact formula: super admin anywhere; an org
-- admin only within their own organization; the meeting's own
-- creator always. Supervisors, room managers, and ordinary staff
-- fall through to FALSE regardless of can_manage_meeting().
CREATE OR REPLACE FUNCTION is_meeting_lock_overridable(p_meeting_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
      m.created_by = auth.uid()
      OR (is_admin() AND m.organization_id = get_my_org_id())
    )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. lock_meeting() / unlock_meeting() RPCs ──────────────────
-- Locking is the creator's own choice only — not something an org
-- admin or super admin initiates on someone else's meeting (docs/23
-- §Phase B/§4). Unlocking uses the broader override tier, since
-- "override" in the approved Q2 decision includes lifting the lock
-- outright.
CREATE OR REPLACE FUNCTION lock_meeting(
  p_meeting_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'lock_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot lock a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF v_meeting.created_by <> v_actor THEN
    RAISE EXCEPTION 'Only the meeting creator can lock this meeting';
  END IF;
  IF v_meeting.is_locked THEN
    RAISE EXCEPTION 'This meeting is already locked';
  END IF;

  UPDATE meetings SET is_locked = TRUE, locked_by = v_actor, locked_at = now() WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'meeting_locked', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlock_meeting(
  p_meeting_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlock_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot unlock a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF NOT v_meeting.is_locked THEN
    RAISE EXCEPTION 'This meeting is not locked';
  END IF;
  IF NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to unlock this meeting';
  END IF;

  UPDATE meetings SET is_locked = FALSE, locked_by = NULL, locked_at = NULL WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'meeting_unlocked', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Lock enforcement in every existing mutating RPC that ────
-- ─── touches a meeting or its participants/bookings/minutes/ ────
-- ─── attendance (docs/23 §Phase B/§4's named 4, plus every other ──
-- ─── can_manage_meeting()-gated RPC found by inspection — the ────
-- ─── explicit "no unintended write path" requirement) ───────────
-- Every check below is inserted immediately after each function's
-- existing "meeting not found / already cancelled" guard and BEFORE
-- its own can_manage_meeting()/authorization check, so a locked
-- meeting rejects a non-overriding caller before any other business
-- logic runs. Every other line in each function below is unchanged
-- from its previously shipped version — body-only changes, no
-- signature/return-type change, so no DROP FUNCTION is required for
-- any of them.

-- update_meeting(): body-only change (lock check added).
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
  p_virtual_link TEXT DEFAULT NULL
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
    virtual_link = v_new_virtual_link
  WHERE id = p_meeting_id;

  IF v_time_changed THEN
    SELECT * INTO v_booking FROM meeting_room_bookings
      WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
    IF FOUND THEN
      PERFORM reschedule_booking(v_booking.id, NULL, v_new_start, v_new_end, v_new_tz);
    END IF;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'edited', 'meeting', p_meeting_id);

  IF v_publishing THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_created', 'meeting', p_meeting_id,
      'You have been invited to a meeting: ' || COALESCE(p_title, v_meeting.title)
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  ELSIF v_meaningful_change THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_updated', 'meeting', p_meeting_id, 'A meeting you are part of was updated.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- cancel_meeting(): body-only change (lock check added).
CREATE OR REPLACE FUNCTION cancel_meeting(
  p_meeting_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL
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

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'meeting_cancelled', 'meeting', p_meeting_id, 'A meeting you are part of has been cancelled.'
  FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- add_participant(): body-only change (lock check added).
CREATE OR REPLACE FUNCTION add_participant(
  p_meeting_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_external_name TEXT DEFAULT NULL,
  p_external_email TEXT DEFAULT NULL,
  p_external_phone TEXT DEFAULT NULL,
  p_external_organization_name TEXT DEFAULT NULL,
  p_participant_role TEXT DEFAULT 'attendee',
  p_notes TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_participant_id UUID;
  v_is_organizer BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'add_participant requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot add a participant to a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may manage participants';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to manage participants for this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF (p_user_id IS NOT NULL) = (p_external_name IS NOT NULL) THEN
    RAISE EXCEPTION 'Provide exactly one of user_id or external_name';
  END IF;
  IF p_participant_role NOT IN ('organizer', 'attendee', 'observer') THEN
    RAISE EXCEPTION 'Invalid participant_role: %', p_participant_role;
  END IF;

  v_is_organizer := (p_participant_role = 'organizer');

  BEGIN
    INSERT INTO meeting_participants (
      meeting_id, user_id, external_name, external_email, external_phone,
      external_organization_name, participant_role, is_organizer, invited_by, notes
    ) VALUES (
      p_meeting_id, p_user_id, p_external_name, p_external_email, p_external_phone,
      p_external_organization_name, p_participant_role, v_is_organizer, v_actor, p_notes
    ) RETURNING id INTO v_participant_id;
  EXCEPTION WHEN unique_violation THEN
    IF v_is_organizer THEN
      RAISE EXCEPTION 'This meeting already has an organizer';
    ELSE
      RAISE EXCEPTION 'This participant has already been added to the meeting';
    END IF;
  END;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'participant_added', 'meeting', p_meeting_id);

  IF p_user_id IS NOT NULL AND p_user_id <> v_actor THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (p_user_id, 'participant_added', 'meeting', p_meeting_id,
      'You have been added to a meeting: ' || v_meeting.title);
  END IF;

  RETURN v_participant_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- remove_participant(): body-only change (lock check added). Per
-- docs/23 §Phase B/§4's literal instruction, this check applies
-- unconditionally BEFORE the existing v_self-or-can_manage_meeting
-- branch — meaning a locked meeting also freezes a participant's own
-- self-removal, not only manager-initiated removal, unless the actor
-- is the creator/an in-org admin/a super admin.
CREATE OR REPLACE FUNCTION remove_participant(
  p_participant_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
  v_self BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'remove_participant requires an authenticated caller';
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Participant has already been removed';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(v_participant.meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may manage participants';
  END IF;

  v_self := (v_participant.user_id = v_actor);
  IF NOT (v_self OR can_manage_meeting(v_participant.meeting_id)) THEN
    RAISE EXCEPTION 'Not authorized to remove this participant';
  END IF;
  IF v_participant.is_organizer THEN
    RAISE EXCEPTION 'Cannot remove the meeting''s sole organizer';
  END IF;

  UPDATE meeting_participants SET
    removed_at = now(), removed_by = v_actor, removal_reason = p_reason
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'participant_removed', 'meeting', v_participant.meeting_id, p_reason);

  IF v_participant.user_id IS NOT NULL AND NOT v_self THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_participant.user_id, 'participant_removed', 'meeting', v_participant.meeting_id,
      'You have been removed from a meeting: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- assign_room_booking(): body-only change (lock check added). Not
-- named in docs/23's literal 4-item list (written before this RPC's
-- own patch existed) but found by the mandated inspection pass —
-- it mutates the meeting (location_mode) via can_manage_meeting(),
-- so it is in scope exactly like the 4 named functions.
CREATE OR REPLACE FUNCTION assign_room_booking(
  p_meeting_id UUID,
  p_room_id UUID
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
    v_booking_id := submit_booking_request(p_room_id, v_meeting.start_at, v_meeting.end_at, v_meeting.timezone, p_meeting_id);
  END IF;

  UPDATE meetings SET location_mode = 'room' WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'assigned', 'meeting', p_meeting_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'room_assigned', 'meeting', p_meeting_id, 'A room has been assigned to a meeting you are part of.'
  FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- detach_room_booking(): body-only change (lock check added). Same
-- inspection-pass rationale as assign_room_booking above.
CREATE OR REPLACE FUNCTION detach_room_booking(
  p_meeting_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'detach_room_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may detach a room';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to detach a room from this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This meeting has no active room booking to detach';
  END IF;

  UPDATE meeting_room_bookings SET
    status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
    cancellation_reason = COALESCE(p_reason, 'Room detached from meeting')
    WHERE id = v_booking.id;

  UPDATE meetings SET location_mode = NULL WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'meeting', p_meeting_id, p_reason);
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, p_reason);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- mark_attendance(): body-only change (lock check added). Found by
-- the mandated inspection pass; requirement 2 explicitly names
-- "mark attendance" as a blocked action on a locked meeting.
CREATE OR REPLACE FUNCTION mark_attendance(
  p_participant_id UUID,
  p_status TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_attendance requires an authenticated caller';
  END IF;
  IF p_status NOT IN ('attended', 'absent', 'excused') THEN
    RAISE EXCEPTION 'Invalid attendance status: % (expected attended, absent, or excused)', p_status;
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot mark attendance on a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(v_participant.meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may mark attendance';
  END IF;
  IF NOT can_manage_meeting(v_participant.meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to mark attendance for this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  UPDATE meeting_participants SET
    attendance_status = p_status,
    attendance_marked_by = v_actor,
    attendance_marked_at = now(),
    attendance_note = p_note
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'attendance_marked', 'meeting', v_meeting.id, p_note);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- update_minutes(): body-only change (lock check added, evaluated
-- before the existing finalized/not-finalized tier branching, so a
-- lock blocks a normal manager even while minutes are not yet
-- finalized).
CREATE OR REPLACE FUNCTION update_minutes(
  p_meeting_id UUID,
  p_minutes TEXT
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_minutes requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot update minutes on a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may modify its minutes';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF v_meeting.minutes_finalized THEN
    IF NOT (is_super_admin() OR (is_admin() AND v_meeting.organization_id = get_my_org_id())) THEN
      RAISE EXCEPTION 'Minutes have been finalized — only an organization administrator or super administrator may edit them now';
    END IF;
  ELSE
    IF NOT can_manage_meeting(p_meeting_id) THEN
      RAISE EXCEPTION 'Not authorized to edit minutes for this meeting';
    END IF;
  END IF;

  UPDATE meetings SET
    minutes = p_minutes,
    minutes_updated_by = v_actor,
    minutes_updated_at = now()
    WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'minutes_updated', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- finalize_minutes(): body-only change (lock check added).
CREATE OR REPLACE FUNCTION finalize_minutes(
  p_meeting_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'finalize_minutes requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot finalize minutes on a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may finalize its minutes';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF NOT (is_super_admin() OR (is_supervisor_or_above() AND v_meeting.organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to finalize minutes for this meeting';
  END IF;
  IF v_meeting.minutes IS NULL OR btrim(v_meeting.minutes) = '' THEN
    RAISE EXCEPTION 'Cannot finalize empty minutes — add minutes first';
  END IF;
  IF v_meeting.minutes_finalized THEN
    RAISE EXCEPTION 'Minutes have already been finalized';
  END IF;

  UPDATE meetings SET minutes_finalized = TRUE WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'minutes_finalized', 'meeting', p_meeting_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. Closing the booking-level bypass ─────────────────────────
-- cancel_booking()/reschedule_booking() (supabase/patch-rooms-
-- booking-foundation.sql, extended in patch-meetings-foundation.sql)
-- are generic room-booking RPCs, gated on the BOOKING's own
-- created_by/room-manager/admin authority — NOT can_manage_meeting().
-- Found by the mandated inspection pass: without this section, a
-- non-creator meeting manager who assigned a locked meeting's room
-- (and is therefore that booking's created_by), or that room's own
-- manager, could still reschedule/cancel the meeting's active
-- booking directly, entirely bypassing the meeting-level lock check
-- added above — a real "unintended write path" for exactly the
-- "reschedule"/"cancel" actions requirement 2 names. Both RPCs are
-- also used for bookings with no meeting at all (meeting_id IS
-- NULL); that path is completely untouched below — the new check is
-- gated on v_booking.meeting_id IS NOT NULL so standalone room
-- bookings behave identically to before this patch.
-- approve_booking()/reject_booking() were reviewed and deliberately
-- left unmodified: both are gated entirely on the room's own
-- manager/admin authority (a distinct control plane from meeting
-- management), fire only on an as-yet-undecided pending/hold
-- request, and adding a meeting-lock gate there would let a locked
-- meeting jam a room manager's own approval queue for a request they
-- did not create — an unrelated regression, not a closed bypass.
CREATE OR REPLACE FUNCTION cancel_booking(
  p_booking_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
  v_is_manager BOOLEAN;
  v_meeting_locked BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  IF v_booking.status NOT IN ('hold', 'pending', 'confirmed') THEN
    RAISE EXCEPTION 'Booking cannot be cancelled from its current status (%)', v_booking.status;
  END IF;

  IF v_booking.meeting_id IS NOT NULL THEN
    SELECT is_locked INTO v_meeting_locked FROM meetings WHERE id = v_booking.meeting_id;
    IF v_meeting_locked AND NOT is_meeting_lock_overridable(v_booking.meeting_id) THEN
      RAISE EXCEPTION 'This booking is linked to a locked meeting; only the meeting''s creator, an organization administrator (within their own organization), or a super administrator may cancel it';
    END IF;
  END IF;

  v_is_manager := is_room_manager(v_booking.room_id, v_actor) OR is_admin();

  IF v_booking.created_by = v_actor THEN
    IF v_booking.start_at <= now() THEN
      RAISE EXCEPTION 'Cannot cancel a booking that has already started';
    END IF;
  ELSIF v_is_manager THEN
    IF p_cancellation_reason IS NULL OR btrim(p_cancellation_reason) = '' THEN
      RAISE EXCEPTION 'A cancellation reason is required';
    END IF;
  ELSE
    RAISE EXCEPTION 'Not authorized to cancel this booking';
  END IF;

  UPDATE meeting_room_bookings
    SET status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
        cancellation_reason = p_cancellation_reason
    WHERE id = p_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting_room_booking', p_booking_id, p_cancellation_reason);

  IF v_actor = v_booking.created_by THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'booking_cancelled', 'meeting_room_booking', p_booking_id,
      'A room booking request has been cancelled by its requester.'
    FROM room_manager_recipient_ids(v_booking.room_id, v_actor) AS uid;
  ELSIF v_booking.created_by IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_booking.created_by, 'booking_cancelled', 'meeting_room_booking', p_booking_id,
      'Your room booking has been cancelled.');
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- reschedule_booking(): the 5-parameter version (p_new_timezone
-- added by patch-meetings-foundation.sql) — signature unchanged here,
-- body-only change, no DROP FUNCTION required.
CREATE OR REPLACE FUNCTION reschedule_booking(
  p_booking_id UUID,
  p_new_room_id UUID DEFAULT NULL,
  p_new_start_at TIMESTAMPTZ DEFAULT NULL,
  p_new_end_at TIMESTAMPTZ DEFAULT NULL,
  p_new_timezone TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
  v_new_room meeting_rooms;
  v_new_room_id UUID;
  v_new_start TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
  v_new_tz TEXT;
  v_meeting_locked BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reschedule_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  IF v_booking.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'Only a pending or confirmed booking can be rescheduled (status: %)', v_booking.status;
  END IF;

  IF v_booking.meeting_id IS NOT NULL THEN
    SELECT is_locked INTO v_meeting_locked FROM meetings WHERE id = v_booking.meeting_id;
    IF v_meeting_locked AND NOT is_meeting_lock_overridable(v_booking.meeting_id) THEN
      RAISE EXCEPTION 'This booking is linked to a locked meeting; only the meeting''s creator, an organization administrator (within their own organization), or a super administrator may reschedule it';
    END IF;
  END IF;

  IF NOT (v_booking.created_by = v_actor OR is_room_manager(v_booking.room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to reschedule this booking';
  END IF;

  v_new_room_id := COALESCE(p_new_room_id, v_booking.room_id);
  v_new_start := COALESCE(p_new_start_at, v_booking.start_at);
  v_new_end := COALESCE(p_new_end_at, v_booking.end_at);
  v_new_tz := COALESCE(p_new_timezone, v_booking.timezone);
  IF v_new_end <= v_new_start THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;

  IF v_new_room_id <> v_booking.room_id THEN
    SELECT * INTO v_new_room FROM meeting_rooms WHERE id = v_new_room_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Target room not found or inactive';
    END IF;
    IF v_new_room.org_id <> v_booking.org_id THEN
      RAISE EXCEPTION 'Cannot reschedule a booking to a room in a different organization';
    END IF;
  END IF;

  UPDATE meeting_room_bookings
    SET room_id = v_new_room_id, start_at = v_new_start, end_at = v_new_end, timezone = v_new_tz
    WHERE id = p_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'rescheduled', 'meeting_room_booking', p_booking_id);

  IF v_actor = v_booking.created_by THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'booking_changed', 'meeting_room_booking', p_booking_id,
      'A room booking has been rescheduled by its requester.'
    FROM room_manager_recipient_ids(v_new_room_id, v_actor) AS uid;
  ELSIF v_booking.created_by IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_booking.created_by, 'booking_changed', 'meeting_room_booking', p_booking_id,
      'Your room booking has been rescheduled.');
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. RLS: attachments — lock guard on the meeting branch ─────
-- No incremental ALTER POLICY exists for adding a condition to one
-- branch — the full attachments_insert/attachments_delete policies
-- are restated (DROP+CREATE) with every existing branch preserved
-- verbatim (same convention documented in patch-meetings-foundation.
-- sql §10), and only the 'meeting' branch gains the lock guard.
-- attachments_select is intentionally untouched — requirement 7:
-- existing read access is unchanged by locking.
DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'meeting' AND can_manage_meeting(record_id) AND EXISTS (
        SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'
          AND (m.is_locked = FALSE OR is_meeting_lock_overridable(record_id))
      ))
    )
  );

DROP POLICY IF EXISTS "attachments_delete" ON attachments;
CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'meeting' AND EXISTS (
        SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'
          AND (m.is_locked = FALSE OR is_meeting_lock_overridable(record_id))
      ))
    )
  );

-- ─── 7. audit_logs CHECK extension ──────────────────────────────
-- Full accumulated list restated (per docs/23 §0's coordination
-- note), not a bare addition — every value already present in
-- patch-meetings-minutes.sql's own extension, plus exactly two new
-- values. No notifications.type change accompanies this patch —
-- docs/23 §Phase B/§7 lists meeting_locked/meeting_unlocked as
-- optional/not-required-for-parity and recommends deferring unless
-- requested, matching the same judgment already applied to
-- attendance_marked/minutes_updated/minutes_finalized.
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
    'meeting_locked', 'meeting_unlocked'
  ));

COMMIT;
