-- Rollback for patch-rooms-auto-confirm-bookings.sql (147).
-- Restores create_room_booking()/assign_room_booking() to their pre-147
-- bodies (patch-rooms-booking-foundation.sql's), reinstating the
-- manager-vs-request-approval split.
--
-- Does NOT revert bookings this patch auto-confirmed back to 'pending'
-- — that would silently re-introduce an approval requirement on
-- bookings the requester (and everyone who saw the "confirmed" status
-- since) already reasonably believes are settled. If that's genuinely
-- needed, do it as an explicit, separate, reviewed data change.

BEGIN;

CREATE OR REPLACE FUNCTION create_room_booking(
  p_room_id UUID, p_start_at TIMESTAMPTZ, p_end_at TIMESTAMPTZ,
  p_timezone TEXT DEFAULT 'Indian/Maldives', p_meeting_id UUID DEFAULT NULL, p_section_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_booking_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_room_booking requires an authenticated caller';
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
  IF NOT is_room_manager(p_room_id, v_actor) AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized to directly confirm a booking for this room';
  END IF;

  INSERT INTO meeting_room_bookings (
    org_id, room_id, meeting_id, section_id, status,
    start_at, end_at, timezone, created_by, approved_by, approved_at
  ) VALUES (
    v_room.org_id, p_room_id, p_meeting_id, p_section_id, 'confirmed',
    p_start_at, p_end_at, p_timezone, v_actor, v_actor, now()
  ) RETURNING id INTO v_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting_room_booking', v_booking_id);

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION assign_room_booking(p_meeting_id UUID, p_room_id UUID, p_suppress_notification BOOLEAN DEFAULT FALSE)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking_id UUID;
  v_suppress_participant_notification BOOLEAN;
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

  v_suppress_participant_notification := p_suppress_notification OR (v_meeting.status = 'draft');

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

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'assigned', 'meeting', p_meeting_id);

  IF NOT v_suppress_participant_notification THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'room_assigned', 'meeting', p_meeting_id, 'A room has been assigned to a meeting you are part of.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
