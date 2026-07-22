-- ============================================================
-- CorLink — Meetings Database Foundation
-- Implements docs/12-meetings-v1-decisions.md and
-- docs/13-meetings-technical-readiness.md exactly.
--
-- Depends on the already-implemented Rooms and Booking foundation
-- (supabase/patch-rooms-booking-foundation.sql) — must be applied
-- first. Creates: meetings, meeting_participants. Extends the
-- existing meeting_room_bookings table (FK, one-active-booking
-- constraint, meeting-linkage trigger) and reschedule_booking() (adds
-- p_new_timezone, additive only). 7 RPCs. SELECT-only RLS on both new
-- tables. Extends attachments/notifications/audit_logs CHECK
-- constraints. No recurring meetings, no meeting groups/ACLs, no
-- reminders/cron, no Telegram/email, no room or booking attachments.
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. meetings ────────────────────────────────────────────
-- organization_id (not org_id) per docs/12 §4 — a deliberate naming
-- difference from meeting_rooms.org_id, not an inconsistency.
CREATE TABLE IF NOT EXISTS meetings (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID        NOT NULL REFERENCES organizations(id),
  created_by          UUID        NOT NULL REFERENCES users(id),
  updated_by          UUID        REFERENCES users(id),
  title               TEXT        NOT NULL,
  description         TEXT,
  meeting_type        TEXT        NOT NULL DEFAULT 'general',
  status              TEXT        NOT NULL DEFAULT 'draft',
  visibility          TEXT        NOT NULL DEFAULT 'participants',
  location_mode       TEXT,
  timezone            TEXT        NOT NULL DEFAULT 'Indian/Maldives',
  start_at            TIMESTAMPTZ NOT NULL,
  end_at              TIMESTAMPTZ NOT NULL,
  external_location   TEXT,
  virtual_link        TEXT,
  cancellation_reason TEXT,
  cancelled_by        UUID        REFERENCES users(id),
  cancelled_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meetings_title_check CHECK (btrim(title) <> ''),
  CONSTRAINT meetings_type_check CHECK (meeting_type IN (
    'general', 'interview', 'training', 'operational', 'administrative', 'other'
  )),
  CONSTRAINT meetings_status_check CHECK (status IN ('draft', 'scheduled', 'cancelled')),
  CONSTRAINT meetings_visibility_check CHECK (visibility IN ('private', 'participants', 'organization')),
  CONSTRAINT meetings_location_mode_check CHECK (location_mode IS NULL OR location_mode IN ('room', 'external', 'virtual')),
  CONSTRAINT meetings_range_check CHECK (end_at > start_at),
  CONSTRAINT meetings_external_location_check CHECK (location_mode <> 'external' OR external_location IS NOT NULL),
  CONSTRAINT meetings_virtual_link_check CHECK (location_mode <> 'virtual' OR virtual_link IS NOT NULL),
  CONSTRAINT meetings_virtual_link_scheme_check CHECK (virtual_link IS NULL OR virtual_link ~ '^https://'),
  -- Bidirectional (docs/12 §7): cancellation is genuinely terminal, so
  -- unlike the one-directional pattern used for booking
  -- approval/rejection fields, a non-cancelled row must never carry
  -- stale cancellation metadata.
  CONSTRAINT meetings_cancel_alignment_check
    CHECK ((status = 'cancelled') = (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_meetings_organization ON meetings(organization_id);
CREATE INDEX IF NOT EXISTS idx_meetings_created_by ON meetings(created_by);

-- Generic — not meetings-specific. Confirmed absent from the entire
-- codebase before writing this (docs/13 §4 assumed it already existed
-- from Rooms/Booking; it did not — created here instead).
CREATE OR REPLACE FUNCTION trigger_set_updated_by()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_by = auth.uid();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_updated_at ON meetings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meetings
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
DROP TRIGGER IF EXISTS set_updated_by ON meetings;
CREATE TRIGGER set_updated_by BEFORE UPDATE ON meetings
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_by();

-- ─── 2. Effective completion helper (docs/12 §4, docs/13 §6) ──
CREATE OR REPLACE FUNCTION meeting_effective_status(p_status TEXT, p_end_at TIMESTAMPTZ)
RETURNS TEXT AS $$
  SELECT CASE WHEN p_status = 'scheduled' AND p_end_at < now() THEN 'completed' ELSE p_status END;
$$ LANGUAGE sql STABLE;

-- ─── 3. Status-transition enforcement (docs/12 §3/§4) ─────────
CREATE OR REPLACE FUNCTION valid_meeting_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'scheduled'), ('draft', 'cancelled'), ('scheduled', 'cancelled')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_meeting_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_meeting_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid meeting status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_meeting_status ON meetings;
CREATE TRIGGER check_meeting_status BEFORE UPDATE OF status ON meetings
  FOR EACH ROW EXECUTE FUNCTION trigger_check_meeting_status();

-- ─── 4. meeting_participants (docs/12 §8/§9, docs/13 §4/§5) ───
CREATE TABLE IF NOT EXISTS meeting_participants (
  id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  meeting_id                  UUID        NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  user_id                     UUID        REFERENCES users(id),
  external_name               TEXT,
  external_email              TEXT,
  external_phone              TEXT,
  external_organization_name  TEXT,
  participant_role            TEXT        NOT NULL DEFAULT 'attendee',
  invitation_status           TEXT        NOT NULL DEFAULT 'pending',
  attendance_status           TEXT        NOT NULL DEFAULT 'unknown',
  is_organizer                BOOLEAN     NOT NULL DEFAULT FALSE,
  invited_by                  UUID        NOT NULL REFERENCES users(id),
  removed_at                  TIMESTAMPTZ,
  removed_by                  UUID        REFERENCES users(id),
  removal_reason              TEXT,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_participants_identity_check CHECK (
    (user_id IS NOT NULL AND external_name IS NULL) OR
    (user_id IS NULL AND external_name IS NOT NULL)
  ),
  CONSTRAINT meeting_participants_role_check CHECK (participant_role IN ('organizer', 'attendee', 'observer')),
  CONSTRAINT meeting_participants_invitation_check CHECK (invitation_status IN ('pending', 'accepted', 'declined', 'not_required')),
  CONSTRAINT meeting_participants_attendance_check CHECK (attendance_status IN ('unknown', 'attended', 'absent', 'excused')),
  -- Permanently synchronized (docs/12 §8) — "which field is
  -- authoritative" is never an askable question.
  CONSTRAINT meeting_participants_organizer_sync_check CHECK ((participant_role = 'organizer') = is_organizer)
);
CREATE INDEX IF NOT EXISTS idx_meeting_participants_meeting ON meeting_participants(meeting_id);
CREATE INDEX IF NOT EXISTS idx_meeting_participants_user ON meeting_participants(user_id) WHERE user_id IS NOT NULL;

-- Internal dedup — re-addable after a prior removal (docs/12 §9).
CREATE UNIQUE INDEX IF NOT EXISTS meeting_participants_internal_unique
  ON meeting_participants(meeting_id, user_id) WHERE user_id IS NOT NULL AND removed_at IS NULL;
-- External dedup by normalized email — only when an email is supplied.
CREATE UNIQUE INDEX IF NOT EXISTS meeting_participants_external_email_unique
  ON meeting_participants(meeting_id, lower(external_email)) WHERE external_email IS NOT NULL AND removed_at IS NULL;
-- At most one active organizer.
CREATE UNIQUE INDEX IF NOT EXISTS meeting_participants_one_organizer
  ON meeting_participants(meeting_id) WHERE is_organizer = TRUE AND removed_at IS NULL;

DROP TRIGGER IF EXISTS set_updated_at ON meeting_participants;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_participants
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 5. meeting_room_bookings extensions (docs/12 §10, docs/13 §10) ──
-- The FK deliberately deferred by the Rooms/Booking migration
-- (meetings didn't exist yet) is added now that it does. If this
-- migration was previously rolled back (docs/rollback/003) and any
-- meeting_room_bookings row still carries a meeting_id from a
-- since-dropped meetings table, this ADD CONSTRAINT fails until that
-- dangling reference is nulled first — see docs/rollback/003 §1b for
-- the exact statement (a real, tested finding from this migration's
-- own rollback-then-reapply cycle, not a hypothetical).
ALTER TABLE meeting_room_bookings DROP CONSTRAINT IF EXISTS meeting_room_bookings_meeting_id_fkey;
ALTER TABLE meeting_room_bookings
  ADD CONSTRAINT meeting_room_bookings_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES meetings(id);

-- At most one active (hold/pending/confirmed) linked booking per meeting.
CREATE UNIQUE INDEX IF NOT EXISTS meeting_room_bookings_one_active_per_meeting
  ON meeting_room_bookings(meeting_id) WHERE meeting_id IS NOT NULL AND status IN ('hold', 'pending', 'confirmed');

-- Kept entirely separate from meeting_room_bookings_conflict_guard()
-- (already shipped, unmodified) — a genuinely different concern
-- (meeting-linkage consistency, not room-availability), per docs/13
-- §10's own deliberate separation-of-concerns rationale.
CREATE OR REPLACE FUNCTION meeting_room_bookings_meeting_link_guard()
RETURNS TRIGGER AS $$
DECLARE
  v_meeting_org UUID;
  v_meeting_start TIMESTAMPTZ;
  v_meeting_end TIMESTAMPTZ;
  v_meeting_tz TEXT;
BEGIN
  IF NEW.meeting_id IS NOT NULL AND NEW.status IN ('hold', 'pending', 'confirmed') THEN
    SELECT organization_id, start_at, end_at, timezone
      INTO v_meeting_org, v_meeting_start, v_meeting_end, v_meeting_tz
      FROM meetings WHERE id = NEW.meeting_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Linked meeting not found';
    END IF;
    IF v_meeting_org <> NEW.org_id THEN
      RAISE EXCEPTION 'Booking organization does not match its meeting''s organization';
    END IF;
    IF NEW.start_at <> v_meeting_start OR NEW.end_at <> v_meeting_end THEN
      RAISE EXCEPTION 'Booking time does not match its meeting''s time';
    END IF;
    IF NEW.timezone <> v_meeting_tz THEN
      RAISE EXCEPTION 'Booking timezone (%) must match its meeting''s timezone (%)', NEW.timezone, v_meeting_tz;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS meeting_link_guard ON meeting_room_bookings;
CREATE TRIGGER meeting_link_guard
  BEFORE INSERT OR UPDATE OF meeting_id, org_id, start_at, end_at, timezone, status ON meeting_room_bookings
  FOR EACH ROW EXECUTE FUNCTION meeting_room_bookings_meeting_link_guard();

-- ─── 6. reschedule_booking() extension (docs/13 §10) ──────────
-- One required, additive touch to the already-shipped RPC: adds
-- p_new_timezone and extends the final UPDATE's SET clause to include
-- it. Every other line is unchanged from the shipped version —
-- room_id/start_at/end_at were already unconditionally in the SET
-- clause (via COALESCE), so the existing BEFORE UPDATE OF room_id,
-- start_at, end_at, status trigger already fires on every call
-- regardless; adding timezone to that same SET clause is sufficient
-- to bring timezone-only changes inside both the conflict-guard's and
-- the new meeting-link-guard's watch, with no trigger column-list
-- change needed. Existing callers that omit the new parameter see
-- identical behavior (timezone simply stays unchanged via COALESCE).
-- The old 4-parameter overload is dropped explicitly first — CREATE
-- OR REPLACE alone would add a second overload rather than replacing
-- it, since Postgres distinguishes functions by argument signature,
-- not name alone (the same real gap found and fixed for
-- assign_room_booking above applies identically here).
DROP FUNCTION IF EXISTS reschedule_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ);
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

-- ─── 7. Helper functions (docs/13 §1/§7/§8/§15) ───────────────

CREATE OR REPLACE FUNCTION meetings_module_active_for(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_module_active('meetings') AND module_enabled_for_org(p_org_id, 'meetings');
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- docs/12 §6's resolved visibility semantics: private/participants
-- both reduce to creator + active participant + org supervisor/admin
-- + super admin; 'organization' visibility only ever ADDS the
-- org-wide grant, never removes the baseline.
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
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

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
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION meeting_participant_recipient_ids(p_meeting_id UUID, p_exclude UUID DEFAULT NULL)
RETURNS SETOF UUID AS $$
  SELECT DISTINCT mp.user_id
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.user_id IS NOT NULL AND mp.removed_at IS NULL
    AND (p_exclude IS NULL OR mp.user_id <> p_exclude);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Safe, redacted participant read (docs/12 §13, docs/13 §8) — the raw
-- table's own SELECT policy (§9 below) is narrower than this function
-- on purpose; this is what the frontend calls for "everyone in this
-- meeting," never nulling a privileged caller's view, always nulling
-- external_email/external_phone for a non-privileged caller.
CREATE OR REPLACE FUNCTION meeting_participant_list(p_meeting_id UUID)
RETURNS TABLE (
  id UUID, user_id UUID, external_name TEXT, external_email TEXT, external_phone TEXT,
  external_organization_name TEXT, participant_role TEXT, invitation_status TEXT,
  attendance_status TEXT, is_organizer BOOLEAN, notes TEXT, created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_privileged BOOLEAN;
BEGIN
  IF NOT can_view_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to view this meeting''s participants';
  END IF;
  v_privileged := can_manage_meeting(p_meeting_id);

  RETURN QUERY
  SELECT mp.id, mp.user_id, mp.external_name,
    CASE WHEN v_privileged THEN mp.external_email ELSE NULL END,
    CASE WHEN v_privileged THEN mp.external_phone ELSE NULL END,
    mp.external_organization_name, mp.participant_role, mp.invitation_status,
    mp.attendance_status, mp.is_organizer, mp.notes, mp.created_at
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.removed_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. RPCs (docs/12 §17, docs/13 §9) ─────────────────────────
-- All SECURITY DEFINER, search_path pinned, actor from auth.uid()
-- only, refuse a NULL actor outright. No complete_meeting (derived
-- only, §2 above).

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
  p_virtual_link TEXT DEFAULT NULL
) RETURNS UUID AS $$
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

  -- Creator auto-inserted as the sole organizer (docs/12 §8).
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invitation_status, is_organizer, invited_by)
  VALUES (v_meeting_id, v_actor, 'organizer', 'accepted', TRUE, v_actor);

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting', v_meeting_id);

  RETURN v_meeting_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

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

  -- Location-field validation against the OLD row's values via
  -- COALESCE, evaluated before the meetings UPDATE below.
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

  -- 1. UPDATE THE MEETING'S OWN ROW FIRST (docs/13 §13) — including
  --    any new start_at/end_at/timezone — so that the meeting-link
  --    trigger fired by step 2's booking sync below sees the
  --    meeting's CURRENT, already-updated values, not stale ones.
  --    Reordering this after the booking sync reproduces the exact
  --    class of bug already found and fixed once during an earlier
  --    iteration of an analogous function — see docs/13 §13.
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

  -- 2. THEN, only if time/timezone actually changed AND an active
  --    booking is linked, sync it via the trusted, existing RPC. Any
  --    exception here propagates out and aborts this entire call,
  --    INCLUDING step 1's meetings UPDATE — ordinary PL/pgSQL
  --    exception propagation, not a special rollback mechanism.
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
    -- Direct UPDATE, not a nested call to cancel_booking() — that
    -- RPC's own authorization (requester-or-room-manager) may not be
    -- satisfied by a meeting-managing supervisor with no direct
    -- relationship to the room. can_manage_meeting's broader,
    -- already-established authority is applied directly instead.
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

-- No p_start_at/p_end_at override parameters: the meeting_link_guard
-- trigger (§5 above) requires a linked active booking's start_at/
-- end_at/timezone to exactly match its meeting's — a caller-supplied
-- window differing from the meeting's own would therefore always be
-- rejected by that trigger. Rather than expose parameters that can
-- only ever be used with the meeting's own values (or never
-- successfully with anything else), the booking always uses the
-- meeting's own start_at/end_at/timezone directly. Found via local
-- concurrency testing (an earlier draft exposed these as overridable
-- parameters, which failed immediately in a two-different-meetings
-- test — see docs/14 for the full note). The old 4-parameter overload
-- is dropped explicitly — CREATE OR REPLACE alone would add a second
-- overload rather than replacing it, since Postgres distinguishes
-- functions by argument signature, not name alone.
DROP FUNCTION IF EXISTS assign_room_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ);
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

  -- Delegates to the existing, trusted booking RPCs — never a raw
  -- INSERT — so the conflict engine is never duplicated (docs/12
  -- §10). Same actor re-checked by the delegate's own authorization,
  -- justifying the direct (non-replicated) call.
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

  -- Direct UPDATE, not a nested call to cancel_booking() — same
  -- non-nested-call reasoning as cancel_meeting above.
  UPDATE meeting_room_bookings SET
    status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
    cancellation_reason = COALESCE(p_reason, 'Room detached from meeting')
    WHERE id = v_booking.id;

  -- Never left claiming 'room' with nothing attached (docs/12 §10).
  UPDATE meetings SET location_mode = NULL WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'meeting', p_meeting_id, p_reason);
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, p_reason);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 9. RLS (docs/12 §18, docs/13 §7) ──────────────────────────
ALTER TABLE meetings             ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_participants ENABLE ROW LEVEL SECURITY;

-- SELECT only on both — no INSERT/UPDATE/DELETE policy exists for
-- any role; every mutation goes exclusively through the 7 RPCs above.
DROP POLICY IF EXISTS "meetings_select" ON meetings;
CREATE POLICY "meetings_select" ON meetings
  FOR SELECT USING (current_user_module_enabled('meetings') AND can_view_meeting(id));

-- Deliberately narrower than can_view_meeting() — an ordinary
-- participant may read their own row; full raw-table participant
-- visibility (including unredacted contact fields) is manager-only.
-- Anyone with can_view_meeting() gets the safe, redacted list via
-- meeting_participant_list() instead.
DROP POLICY IF EXISTS "meeting_participants_select" ON meeting_participants;
CREATE POLICY "meeting_participants_select" ON meeting_participants
  FOR SELECT USING (
    current_user_module_enabled('meetings')
    AND (can_manage_meeting(meeting_id) OR user_id = auth.uid())
  );

-- ─── 10. Attachment integration (docs/12 §14, docs/13 §14) ─────
-- Reuses the existing attachments table/bucket as-is. Restates the
-- full attachments_select/insert/delete policies (DROP+CREATE is
-- required to change a policy; there is no incremental ALTER POLICY
-- for adding one branch) with every existing branch preserved
-- verbatim, plus one new 'meeting' branch appended to each.
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply',
    'internal_reply', 'external_correspondence', 'external_correspondence_reply', 'meeting'
  ));

DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr
      JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR irr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            irr.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    ))
    OR (record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ))
    OR (record_type = 'external_correspondence_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr
      JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (
          ec.to_section_id IN (SELECT my_section_ids())
          OR ecr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id))
          OR (ecr.status = 'sent' AND (is_entry_staff(ec.org_id) OR ec.entered_by = auth.uid()))
        )
    ))
    OR (record_type = 'meeting' AND can_view_meeting(record_id))
  );

DROP POLICY IF EXISTS "attachments_select_cc" ON attachments;
CREATE POLICY "attachments_select_cc" ON attachments
  FOR SELECT USING (
    record_type IN ('request', 'response') AND is_cc_recipient(record_type, record_id)
  );

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
      -- Uploader-only, same as every other record type — NOT "any
      -- meeting manager may delete anyone's attachment." Widening
      -- this specifically for meetings would require restructuring
      -- the shared uploaded_by wrapper above, touching all 8 other
      -- record types' delete behavior too — explicitly out of scope
      -- (docs/12 §14's own documented, deliberate consistency choice).
      OR (record_type = 'meeting' AND EXISTS (
        SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'
      ))
    )
  );

-- ─── 11. Notification / audit CHECK extensions (docs/12 §15/§16) ──
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention',
    'meeting_created', 'participant_added', 'meeting_updated',
    'room_assigned', 'meeting_cancelled', 'participant_removed'
  ));

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
    'attachment_added', 'attachment_removed'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting'
  ));

COMMIT;
