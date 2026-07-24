-- ============================================================
-- CorLink — Draft / Pre-booked Meetings
-- Implements docs/22 §3.3 Q4 / §6 Phase F and docs/23 Phase F's
-- Draft/Pre-booked Meetings half (the Recurring Meetings half of
-- Phase F already shipped separately — see docs/25).
--
-- Scope, precisely: a single meeting's draft lifecycle only. Bulk
-- pre-booking (date range x days-of-week via create_recurring_meeting's
-- 'custom_days'/is_draft_series path) is NOT implemented by this patch
-- — nothing in the requirements this patch was built from asks for it,
-- and docs/25 §1 already records that Recurring Meetings Phase 1 and
-- Draft/Pre-booked Meetings shipped as two separable pieces of work
-- rather than one combined delivery. Recurring Meetings Phase 2 is
-- untouched.
--
-- Most of the single-draft-meeting lifecycle already existed before
-- this patch: create_meeting(p_status := 'draft') and
-- update_meeting(p_status := 'scheduled') (the "publish"/"activate"
-- transition, already computing v_publishing and firing exactly one
-- meeting_created notification at that point) both shipped with the
-- original Meetings foundation. This patch closes the remaining gaps
-- found by inspecting every meeting-mutating RPC for draft-awareness:
--   1. Suppress participant-facing notifications while a meeting is
--      still a draft (add_participant, remove_participant,
--      update_meeting's meaningful-change path, assign_room_booking's
--      own room_assigned notification) — requirement 5.
--   2. Room-manager-facing notifications for a draft's own room
--      request are DELIBERATELY left unsuppressed — a draft "may or
--      may not have a room" (docs/22 Q4) but once a room is requested,
--      the manager still needs to know to review it; otherwise the
--      booking silently sits pending forever with no alert ever sent
--      (assign_room_booking's participant-only suppression is
--      decoupled from submit_booking_request's own, already-existing
--      p_suppress_notification parameter — the latter is left
--      completely untouched by this patch, still defaulting to FALSE).
--   3. Block respond_to_invitation on a draft (requirement 6 — no RSVP
--      requests while draft).
--   4. Block mark_attendance on a draft (requirement 7).
--   5. Block update_minutes/finalize_minutes on a draft (requirement
--      8 — minutes describe what happened at a meeting that, as a
--      draft, hasn't been confirmed to happen at all yet).
--   6. Block lock_meeting on a draft (requirement 9).
--   7. Block cancel_meeting on a draft — a draft was never announced,
--      so "cancelling" it would incorrectly notify participants about
--      something they were never told about in the first place (the
--      same requirement-5 leak in a different RPC). A draft is edited,
--      published, or deleted — never cancelled. Redirects the caller
--      to the new delete_draft_meeting() below.
--   8. New delete_draft_meeting() RPC — the only hard-delete path this
--      codebase has ever added for a "real" record (every other module
--      only ever soft-cancels/soft-closes). Restricted to status =
--      'draft' rows only; a scheduled meeting still only ever
--      cancels, never hard-deletes. Decouples (nulls, does not delete)
--      any meeting_room_bookings row that ever referenced this draft
--      (meeting_room_bookings.meeting_id has no ON DELETE clause —
--      FK RESTRICT — so the meetings row cannot be removed while any
--      booking, even an already-cancelled one, still references it);
--      cancels any still-active booking first so the room is actually
--      freed; removes attachment metadata rows for the deleted meeting
--      (which would otherwise become permanently invisible to everyone
--      but their uploader, and permanently undeletable even by them,
--      once can_view_meeting()/attachments_delete's 'meeting' branch
--      can no longer find the now-gone meeting); meeting_participants
--      rows cascade automatically via their existing ON DELETE CASCADE
--      FK, no explicit DELETE needed.
--
-- Preserves, unchanged: create_meeting/update_meeting's core draft
-- support, assign_room_booking's room-reservation behavior for a
-- draft (still works exactly as for a scheduled meeting — requirement
-- 3), meeting ids across a draft->scheduled transition (update_meeting
-- always UPDATEs the same row — requirement 11), every existing
-- permission model (can_manage_meeting()/is_meeting_lock_overridable()
-- reused as-is throughout — requirement 12), org isolation (every
-- function below is unconditionally scoped through
-- meetings_module_active_for()/can_manage_meeting(), exactly as
-- before — requirement 13), and meetings/meeting_participants' existing
-- SELECT-only RLS shape (no new table, no new policy — every mutation,
-- including the new delete, continues to go exclusively through a
-- SECURITY DEFINER RPC — requirement 14).
--
-- Requires patch-meetings-foundation.sql, patch-meetings-rsvp.sql,
-- patch-meetings-attendance.sql, patch-meetings-minutes.sql,
-- patch-meetings-lock.sql, patch-meetings-recurring.sql, and
-- patch-meetings-recurring-notifications.sql already applied — every
-- function below is redefined starting from each one's own latest
-- shipped body (confirmed by inspection, not assumed), body-only
-- changes throughout, no signature/return-type change for any of
-- them, so no DROP FUNCTION is required for any of them. Idempotent —
-- safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. update_meeting(): suppress meeting_updated while still draft ──
-- Body otherwise identical to patch-meetings-recurring.sql's version
-- (the latest prior redefinition, including its series_detached
-- bookkeeping). Only the final notification branch changes: the
-- v_publishing branch (draft -> scheduled) is completely unchanged —
-- that IS the intended "announce now" moment, firing meeting_created
-- exactly as before. The meaningful-change branch now additionally
-- requires v_new_status = 'scheduled', so editing a still-draft
-- meeting (v_new_status stays 'draft') never fires meeting_updated —
-- previously this only happened to resolve to zero recipients because
-- a draft typically has no participants yet besides its creator
-- (who is always excluded via meeting_participant_recipient_ids'
-- p_exclude); a draft with additional participants already added
-- would otherwise have leaked a real notification on every edit.
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
    virtual_link = v_new_virtual_link,
    series_detached = CASE WHEN series_id IS NOT NULL THEN TRUE ELSE series_detached END
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
  ELSIF v_meaningful_change AND v_new_status = 'scheduled' THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_updated', 'meeting', p_meeting_id, 'A meeting you are part of was updated.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. cancel_meeting(): reject drafts outright ─────────────────
-- Body otherwise identical to patch-meetings-lock.sql's version. A
-- draft was never announced to anyone; cancelling it would fire
-- meeting_cancelled to meeting_participant_recipient_ids() — the same
-- participant-notification leak requirement 5 exists to prevent, just
-- reached through a different RPC. Redirects to delete_draft_meeting()
-- (§8 below) instead.
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

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'meeting_cancelled', 'meeting', p_meeting_id, 'A meeting you are part of has been cancelled.'
  FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. add_participant(): suppress notification while draft ────
-- Body otherwise identical to patch-meetings-lock.sql's version.
-- Adding participants to a draft remains fully allowed (docs/22 Q4 —
-- "a draft meeting may or may not have participants") — only the
-- "you have been added" notification is suppressed.
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

  IF p_user_id IS NOT NULL AND p_user_id <> v_actor AND v_meeting.status <> 'draft' THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (p_user_id, 'participant_added', 'meeting', p_meeting_id,
      'You have been added to a meeting: ' || v_meeting.title);
  END IF;

  RETURN v_participant_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. remove_participant(): suppress notification while draft ──
-- Body otherwise identical to patch-meetings-lock.sql's version.
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

  IF v_participant.user_id IS NOT NULL AND NOT v_self AND v_meeting.status <> 'draft' THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_participant.user_id, 'participant_removed', 'meeting', v_participant.meeting_id,
      'You have been removed from a meeting: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. assign_room_booking(): suppress the PARTICIPANT notification ──
-- ─── only while draft — the room-manager approval notification is ─────
-- ─── deliberately left untouched (see header note #2 above) ───────────
-- Body otherwise identical to patch-meetings-recurring-notifications.
-- sql's version (the latest prior redefinition, which already added
-- p_suppress_notification for the recurring-series path). The
-- submit_booking_request() call keeps passing p_suppress_notification
-- completely unchanged — a plain draft-only room request (the normal,
-- non-recurring frontend call, which never passes TRUE) still notifies
-- room managers exactly as before. Only this function's OWN
-- room_assigned participant notification gains the extra draft check,
-- via a separate local variable so the two notification audiences stay
-- independently controlled, not accidentally coupled by reusing one
-- flag for both.
CREATE OR REPLACE FUNCTION assign_room_booking(
  p_meeting_id UUID,
  p_room_id UUID,
  p_suppress_notification BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
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

-- ─── 6. respond_to_invitation(): reject on a draft ───────────────
-- Body otherwise identical to patch-meetings-rsvp.sql's version — a
-- draft's participant rows already exist with invitation_status
-- defaulting to 'pending' (an ordinary column default, not itself a
-- "request"), but nothing should let anyone act on it until the
-- meeting is actually published (requirement 6).
CREATE OR REPLACE FUNCTION respond_to_invitation(
  p_participant_id UUID,
  p_response TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'respond_to_invitation requires an authenticated caller';
  END IF;
  IF p_response NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'Invalid response: % (expected accepted or declined)', p_response;
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;
  IF v_participant.user_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'Not authorized to respond on behalf of this participant';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot respond to a cancelled meeting';
  END IF;
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot respond to an invitation for a draft meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  UPDATE meeting_participants SET
    invitation_status = p_response,
    invitation_note = p_note
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'invitation_responded', 'meeting', v_meeting.id, p_note);

  IF v_meeting.created_by <> v_actor THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_meeting.created_by, 'participant_responded', 'meeting', v_meeting.id,
      'A participant has responded to your meeting invitation: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. mark_attendance(): reject on a draft ─────────────────────
-- Body otherwise identical to patch-meetings-lock.sql's version.
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
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot mark attendance on a draft meeting';
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

-- ─── 8. update_minutes() / finalize_minutes(): reject on a draft ──
-- Bodies otherwise identical to patch-meetings-lock.sql's versions.
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
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot update minutes on a draft meeting';
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
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot finalize minutes on a draft meeting';
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

-- ─── 9. lock_meeting(): reject on a draft ────────────────────────
-- Body otherwise identical to patch-meetings-lock.sql's version.
-- unlock_meeting() needs no change: since a draft can never become
-- locked under this new check, is_locked can never be TRUE for one,
-- so unlock_meeting's own existing "is not locked" guard already
-- rejects it — no separate draft check needed there.
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
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot lock a draft meeting';
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

-- ─── 10. delete_draft_meeting(): hard-delete a draft ─────────────
-- The only path in this codebase that ever removes a meeting row
-- entirely rather than soft-cancelling it — restricted to status =
-- 'draft' only. Same authorization as every other meeting-management
-- RPC (can_manage_meeting() — creator, or an org supervisor/admin;
-- requirement 12: no new, narrower permission model invented here).
CREATE OR REPLACE FUNCTION delete_draft_meeting(
  p_meeting_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'delete_draft_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status <> 'draft' THEN
    RAISE EXCEPTION 'Only a draft meeting can be deleted this way — use cancel_meeting for a scheduled meeting';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to delete this draft meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  -- Cancel (not merely detach) any still-active linked room hold/
  -- request first, so the room is genuinely freed and the booking is
  -- left in a real terminal state — same inline pattern cancel_meeting()
  -- already uses for its own linked-booking branch.
  SELECT * INTO v_booking FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
  IF FOUND THEN
    UPDATE meeting_room_bookings SET
      status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
      cancellation_reason = 'Draft meeting deleted'
      WHERE id = v_booking.id;
    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
    VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, 'Draft meeting deleted');
  END IF;

  -- meeting_room_bookings.meeting_id has no ON DELETE clause (FK
  -- RESTRICT, patch-meetings-foundation.sql §5) — any booking that
  -- ever pointed at this draft, active or already cancelled/rejected,
  -- must be decoupled before the meetings row itself can be removed.
  -- Nulling meeting_id (not deleting the booking row) preserves the
  -- Rooms module's own booking history, reusing the same "standalone
  -- booking" shape (meeting_id IS NULL) already modeled everywhere
  -- else in this codebase.
  UPDATE meeting_room_bookings SET meeting_id = NULL WHERE meeting_id = p_meeting_id;

  -- Attachment metadata rows have no FK to meetings (record_id is a
  -- generic polymorphic UUID) so they would not block the DELETE
  -- below, but would otherwise become permanently invisible to
  -- everyone but their own uploader (can_view_meeting() returns FALSE
  -- once the meeting no longer exists) and permanently undeletable
  -- even by them (attachments_delete's 'meeting' branch also requires
  -- the meeting to still exist) — removed here rather than left as an
  -- orphaned, inaccessible row. The underlying Storage object itself
  -- is not separately purged, matching this codebase's existing scope
  -- (no other flow performs Storage cleanup on a metadata delete).
  DELETE FROM attachments WHERE record_type = 'meeting' AND record_id = p_meeting_id;

  -- meeting_participants cascades via its own existing
  -- ON DELETE CASCADE FK — no explicit DELETE needed here.
  DELETE FROM meetings WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'meeting_draft_deleted', 'meeting', p_meeting_id, v_meeting.title);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 11. audit_logs CHECK extension ───────────────────────────────
-- Full accumulated list restated (per docs/23 §0's coordination
-- note), plus exactly one new value: 'meeting_draft_deleted'.
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
    'meeting_locked', 'meeting_unlocked',
    'meeting_group_created', 'meeting_group_updated', 'meeting_group_deleted',
    'meeting_group_members_updated',
    'meeting_series_created',
    'meeting_draft_deleted'
  ));

COMMIT;
