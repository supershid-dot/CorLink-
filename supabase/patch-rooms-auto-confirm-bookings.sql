-- 147: Room bookings confirm immediately — no manager approval step.
--
-- UAT: screenshot of the "Pending Approvals" tab (three of Hussain
-- Zareer's own booking requests awaiting a manager's decision) —
-- "there is no need to approve this requests, once booked the slot is
-- confirmed and room booked for that time unless it is cancelled."
--
-- Previously, `create_room_booking()` (instant 'confirmed' status)
-- was gated to the room's own manager or an admin; anyone else went
-- through `submit_booking_request()` ('pending', needing a manager's
-- Approve/Reject). This removes that gate: any authenticated,
-- module-enabled, same-org caller may now book directly-confirmed,
-- mirroring the org-membership check `submit_booking_request()`
-- already used (reproduced here verbatim, not invented fresh).
--
-- Double-booking is unaffected by this change: `meeting_room_bookings_
-- no_overlap` (an EXCLUDE constraint) already applies to BOTH
-- 'pending' and 'confirmed' rows, so the same slot could never be
-- double-committed either way — the approval step was never the
-- thing preventing conflicts, only the thing adding friction to an
-- otherwise-uncontested booking.
--
-- `submit_booking_request()`/`approve_booking()`/`reject_booking()`
-- are left in place, unused by the frontend as of this patch — a
-- smaller, safer change than dropping working functions nothing
-- currently calls; they remain available for a super admin to invoke
-- directly if ever needed.

-- True current latest predecessor for both functions below:
-- patch-rooms-booking-foundation.sql (neither has been touched since).

CREATE OR REPLACE FUNCTION create_room_booking(
  p_room_id UUID, p_start_at TIMESTAMPTZ, p_end_at TIMESTAMPTZ,
  p_timezone TEXT DEFAULT 'Indian/Maldives', p_meeting_id UUID DEFAULT NULL, p_section_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_actor_org UUID;
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

  -- Was: NOT is_room_manager(p_room_id, v_actor) AND NOT is_admin() —
  -- docs/147 drops the manager-only gate; every booking confirms
  -- immediately now, so the only remaining check is the same org-
  -- membership rule submit_booking_request() already enforced.
  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT is_super_admin() AND v_actor_org <> v_room.org_id THEN
    RAISE EXCEPTION 'Cannot book a room outside your own organization';
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

-- assign_room_booking() (called from the Schedule Meeting form) no
-- longer needs to choose between create_room_booking/
-- submit_booking_request based on is_room_manager() — every path now
-- goes through create_room_booking(), which enforces its own
-- (org-membership, not manager-only) authorization.
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

  v_booking_id := create_room_booking(p_room_id, v_meeting.start_at, v_meeting.end_at, v_meeting.timezone, p_meeting_id);

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

-- Data fix: auto-confirm every booking that's still sitting in
-- 'pending' under the old rule (the three shown in the UAT
-- screenshot, and any others across the platform) — mirrors
-- approve_booking()'s own non-override write shape exactly (status,
-- approved_by, approved_at, the 'approved' audit_logs row, and the
-- 'booking_approved' notification to the requester), just run as a
-- one-time bulk statement rather than one RPC call per booking, since
-- there's no live authenticated session to drive auth.uid() here.
DO $$
DECLARE
  v_super_admin UUID;
BEGIN
  SELECT id INTO v_super_admin FROM users WHERE is_super_admin = TRUE ORDER BY created_at LIMIT 1;

  CREATE TEMP TABLE tmp_auto_confirmed AS
    SELECT id, created_by FROM meeting_room_bookings WHERE status = 'pending';

  UPDATE meeting_room_bookings
    SET status = 'confirmed', approved_by = v_super_admin, approved_at = now()
    WHERE id IN (SELECT id FROM tmp_auto_confirmed);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  SELECT v_super_admin, 'approved', 'meeting_room_booking', id,
    'Auto-confirmed: room bookings no longer require manager approval (docs/147)'
  FROM tmp_auto_confirmed;

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT created_by, 'booking_approved', 'meeting_room_booking', id,
    'Your room booking request has been approved.'
  FROM tmp_auto_confirmed;

  DROP TABLE tmp_auto_confirmed;
END $$;
