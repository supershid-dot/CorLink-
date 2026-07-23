-- ============================================================
-- CorLink — Recurring Meetings Phase 2: Notification-Suppression
-- Foundation
-- ============================================================
-- Scope, precisely: this patch adds exactly one new trailing
-- parameter, p_suppress_notification BOOLEAN DEFAULT FALSE, to three
-- existing, already-shipped RPCs — update_meeting(), cancel_meeting(),
-- reschedule_booking() — so that future bulk recurring-series RPCs
-- (update_entire_series(), update_series_this_and_future(),
-- cancel_entire_series(), cancel_series_this_and_future(), none of
-- which are implemented by this patch) can reuse this exact mutation
-- logic per-occurrence without generating one participant/room-manager
-- notification per occurrence — the same suppress-then-consolidate
-- pattern already proven for assign_room_booking()/
-- submit_booking_request() in patch-meetings-recurring-notifications.sql.
--
-- Nothing else changes. No recurring-series Phase 2 RPC is implemented
-- here (no create_series_exception, no update_entire_series, no
-- update_series_this_and_future, no cancel_entire_series, no
-- cancel_series_this_and_future, no can_manage_series). No CHECK
-- constraint is touched — no new notification type or audit action is
-- introduced by this patch, since every existing notification/audit
-- INSERT statement is preserved byte-for-byte, only made conditional
-- (notifications) or left fully unconditional (audit, exactly as
-- requirement 4 requires).
--
-- Requires patch-meetings-drafts.sql already applied — update_meeting()
-- and cancel_meeting() below are sourced from that file's own latest
-- shipped bodies (confirmed by direct file inspection, not assumed).
-- reschedule_booking() is sourced from patch-meetings-lock.sql's body
-- (the latest of its three prior redefinitions — patch-rooms-booking-
-- foundation.sql's original 4-parameter version, patch-meetings-
-- foundation.sql's 5-parameter version adding p_new_timezone, then
-- patch-meetings-lock.sql's body-only lock-check addition — confirmed
-- by inspecting all three in sequence).
--
-- Every existing call site (grepped across supabase/*.sql and js/*.js)
-- uses Supabase's named-argument RPC calling convention
-- (db.rpc('fn_name', {p_x: ...})), which PostgREST resolves by
-- parameter NAME, not position — so a purely additive new trailing
-- DEFAULT parameter is compatible with every existing caller
-- automatically, with zero frontend change required (and none made
-- here). The only internal SQL caller of any of these three functions
-- is update_meeting()'s own call to reschedule_booking() (on a time
-- change) — cancel_meeting() has no nested RPC call at all; it cancels
-- its own linked booking via a direct inline UPDATE, never through
-- cancel_booking() or any other notification-producing RPC, so there
-- is nothing to propagate a suppression flag into there.
--
-- DROP FUNCTION IF EXISTS is required before each CREATE OR REPLACE
-- below — Postgres treats a changed argument list as a distinct
-- function identity; without dropping the old signature first, both
-- overloads would coexist and an existing named-argument call
-- (matching both) would fail with "function is not unique" — the same
-- precaution already documented and required in patch-meetings-
-- foundation.sql (for reschedule_booking's own earlier 4-to-5-parameter
-- change) and patch-meetings-recurring-notifications.sql (for
-- assign_room_booking/submit_booking_request's own 2-to-3 and 7-to-8
-- parameter changes).
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. update_meeting(): add p_suppress_notification ────────────
-- Old signature (12 parameters, from patch-meetings-drafts.sql):
--   update_meeting(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ,
--                  TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT)
-- Body identical to patch-meetings-drafts.sql's version in every
-- respect except: (a) one new trailing parameter, (b) both existing
-- notification branches (the v_publishing "announce now" branch and
-- the v_meaningful_change "meeting updated" branch) are now wrapped in
-- one outer suppression check — requirement 4 calls for suppressing
-- every notification this RPC itself would emit, not just one branch
-- of it, and a bulk recurring-series RPC has no legitimate reason to
-- ever want only one of the two suppressed while the other still
-- fires — and (c) its own internal call to reschedule_booking() now
-- explicitly propagates the caller's own p_suppress_notification value
-- (requirement 5) rather than always passing the implicit default of
-- FALSE, so a suppressed bulk edit that also happens to move an
-- occurrence's time can never leak a nested booking_changed
-- notification the caller never asked to see suppressed-or-not
-- independently of the meeting-level flag. No other line changes:
-- validation, permission checks (can_manage_meeting()), lock checks
-- (is_meeting_lock_overridable()), org-isolation
-- (meetings_module_active_for()), the UPDATE statement itself
-- (including series_detached bookkeeping), the reschedule_booking()
-- call's own trigger/conflict path, and the audit_logs INSERT are all
-- byte-for-byte unchanged and fully unconditional, exactly as
-- requirement 3/4 require.
DROP FUNCTION IF EXISTS update_meeting(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT);

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
  p_suppress_notification BOOLEAN DEFAULT FALSE
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
    series_detached = CASE WHEN series_id IS NOT NULL THEN TRUE ELSE series_detached END
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

-- ─── 2. cancel_meeting(): add p_suppress_notification ────────────
-- Old signature (2 parameters, from patch-meetings-drafts.sql):
--   cancel_meeting(UUID, TEXT)
-- Body identical to patch-meetings-drafts.sql's version except: (a)
-- one new trailing parameter, (b) the single participant-facing
-- meeting_cancelled notification is now conditional on it. No nested
-- RPC call exists here to propagate into — the linked room booking is
-- cancelled via a direct inline UPDATE (not a call to cancel_booking()
-- or any other notification-producing function), so there is nothing
-- for this function to thread a suppression flag into; that inline
-- booking cancellation already fires no notification of its own today
-- and continues not to, unchanged. Validation, permission/lock checks,
-- org-isolation, the cancellation-reason requirement, both UPDATE
-- statements, and both audit_logs INSERTs (the linked-booking one and
-- the meeting one) are all byte-for-byte unchanged and fully
-- unconditional.
DROP FUNCTION IF EXISTS cancel_meeting(UUID, TEXT);

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

-- ─── 3. reschedule_booking(): add p_suppress_notification ────────
-- Old signature (5 parameters, from patch-meetings-lock.sql):
--   reschedule_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT)
-- Body identical to patch-meetings-lock.sql's version (the latest of
-- its three prior redefinitions — see this file's header) except: (a)
-- one new trailing parameter, (b) the existing booking_changed
-- notification branch is now conditional on it. Authorization, the
-- linked-meeting lock check (is_meeting_lock_overridable()), the
-- room-conflict-relevant validation (end-after-start, cross-org target
-- room rejection), the UPDATE statement (which is what actually
-- engages the pre-existing EXCLUDE-constraint-plus-advisory-lock
-- conflict enforcement on meeting_room_bookings — untouched, not
-- something this function implements itself), and the audit_logs
-- INSERT are all byte-for-byte unchanged and fully unconditional.
DROP FUNCTION IF EXISTS reschedule_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT);

CREATE OR REPLACE FUNCTION reschedule_booking(
  p_booking_id UUID,
  p_new_room_id UUID DEFAULT NULL,
  p_new_start_at TIMESTAMPTZ DEFAULT NULL,
  p_new_end_at TIMESTAMPTZ DEFAULT NULL,
  p_new_timezone TEXT DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE
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

  IF NOT p_suppress_notification THEN
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
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
