-- ─── Patch: Recurring Meetings — Phase 1 (docs/22 Phase F, docs/23 ──
-- §Phase F) ───────────────────────────────────────────────────────
-- Requires patch-meetings-foundation.sql, patch-meetings-rsvp.sql,
-- patch-meetings-attendance.sql, patch-meetings-minutes.sql,
-- patch-meetings-lock.sql, patch-meetings-personal-notes.sql, and
-- patch-meetings-groups.sql already applied. Implements only the
-- Phase 1 recurring-series scope: weekly/biweekly/monthly, single-
-- transaction bulk creation, individually editable/cancellable
-- occurrences. Deliberately does NOT implement Draft/Pre-booked
-- Meetings (Q4) — the 'custom_days' pattern, days_of_week, and
-- is_draft_series columns exist below purely as inert, forward-
-- compatible schema (same "present now, zero write path yet"
-- treatment already given to meeting_series_exceptions), exactly
-- mirroring how personal_notes/meeting-lock columns were pre-staged
-- in earlier patches before their own RPCs existed. Nothing in this
-- patch ever sets is_draft_series=TRUE or writes days_of_week.
-- Idempotent — safe to re-run.
--
-- ─── The core architectural insight this patch relies on ─────────
-- Every occurrence is an ORDINARY row in meetings, created via the
-- existing, unmodified create_meeting() RPC. Because can_view_meeting()/
-- can_manage_meeting()/meetings_select/meeting_participants_select all
-- key off columns every meeting already has (organization_id,
-- created_by, status, visibility), NOT off series_id, every existing
-- meeting-scoped RPC and RLS policy already works correctly on an
-- occurrence with ZERO changes: respond_to_invitation, mark_attendance,
-- update_minutes, finalize_minutes, get_my_notes, update_my_notes,
-- lock_meeting, unlock_meeting, add_participant, remove_participant,
-- add_group_as_participants, assign_room_booking, detach_room_booking,
-- cancel_meeting. Only update_meeting() needs a one-line addition
-- (series_detached bookkeeping) — see §5 below. This is why this
-- patch's RPC surface is small despite the feature's size.
BEGIN;

-- ─── 1. meeting_series ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_series (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id         UUID        NOT NULL REFERENCES organizations(id),
  created_by              UUID        NOT NULL REFERENCES users(id),
  recurrence_pattern      TEXT        NOT NULL,
  interval_count          INTEGER     NOT NULL DEFAULT 1,
  days_of_week            INTEGER[],
  series_start_date       DATE        NOT NULL,
  series_end_date         DATE        NOT NULL,
  template_title          TEXT        NOT NULL,
  template_description    TEXT,
  template_meeting_type   TEXT        NOT NULL DEFAULT 'general',
  template_visibility     TEXT        NOT NULL DEFAULT 'participants',
  template_start_time     TIME        NOT NULL,
  template_end_time       TIME        NOT NULL,
  template_timezone       TEXT        NOT NULL DEFAULT 'Indian/Maldives',
  template_location_mode  TEXT,
  template_external_location TEXT,
  template_virtual_link   TEXT,
  template_room_id        UUID        REFERENCES meeting_rooms(id),
  -- Q4/Draft-Meetings provenance flag — inert in this phase, never
  -- set TRUE by anything in this patch.
  is_draft_series         BOOLEAN     NOT NULL DEFAULT FALSE,
  -- 'cancelled' has no writer in this phase either — Phase 2's
  -- cancel_entire_series() is what will transition it; present now so
  -- that RPC doesn't need a further migration against live data.
  status                  TEXT        NOT NULL DEFAULT 'active',
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_series_title_check CHECK (btrim(template_title) <> ''),
  CONSTRAINT meeting_series_pattern_check CHECK (recurrence_pattern IN ('weekly', 'biweekly', 'monthly', 'custom_days')),
  CONSTRAINT meeting_series_interval_check CHECK (interval_count >= 1),
  CONSTRAINT meeting_series_date_range_check CHECK (series_end_date >= series_start_date),
  CONSTRAINT meeting_series_time_range_check CHECK (template_end_time > template_start_time),
  CONSTRAINT meeting_series_status_check CHECK (status IN ('active', 'cancelled')),
  CONSTRAINT meeting_series_meeting_type_check CHECK (template_meeting_type IN (
    'general', 'interview', 'training', 'operational', 'administrative', 'other'
  )),
  CONSTRAINT meeting_series_visibility_check CHECK (template_visibility IN ('private', 'participants', 'organization')),
  CONSTRAINT meeting_series_location_mode_check CHECK (template_location_mode IS NULL OR template_location_mode IN ('room', 'external', 'virtual'))
);
CREATE INDEX IF NOT EXISTS idx_meeting_series_org ON meeting_series(organization_id);

DROP TRIGGER IF EXISTS set_updated_at ON meeting_series;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_series
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 2. meetings additions ────────────────────────────────────────
-- All four columns default to NULL/FALSE for every pre-existing row
-- and every future non-recurring meeting — existing meeting ids and
-- behavior are completely unaffected (requirements 5/6).
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS series_id UUID REFERENCES meeting_series(id);
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS series_occurrence_date DATE;
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS series_detached BOOLEAN NOT NULL DEFAULT FALSE;
-- Q4/Draft-Meetings provenance flag — inert in this phase, never set
-- TRUE by anything in this patch; the existing status='draft' value
-- (already shipped, unrelated to this feature) remains the only
-- lifecycle state actually used.
ALTER TABLE meetings ADD COLUMN IF NOT EXISTS is_placeholder BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_meetings_series ON meetings(series_id, series_occurrence_date) WHERE series_id IS NOT NULL;

-- ─── 3. meeting_series_exceptions (Phase 2, inert now) ───────────
-- Schema present now purely so Phase 2 doesn't require a further
-- migration against already-live Phase 1 data (identical treatment
-- to how meeting_group_access-style forward staging was reasoned
-- about in the Meeting Groups patch). Zero RPCs write to this table
-- in this phase; zero UI references it.
CREATE TABLE IF NOT EXISTS meeting_series_exceptions (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id               UUID        NOT NULL REFERENCES meeting_series(id) ON DELETE CASCADE,
  exception_date          DATE        NOT NULL,
  exception_type          TEXT        NOT NULL,
  replacement_meeting_id  UUID        REFERENCES meetings(id),
  created_by              UUID        NOT NULL REFERENCES users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_series_exceptions_type_check CHECK (exception_type IN ('skipped', 'modified')),
  CONSTRAINT meeting_series_exceptions_unique UNIQUE (series_id, exception_date)
);
CREATE INDEX IF NOT EXISTS idx_meeting_series_exceptions_series ON meeting_series_exceptions(series_id);

-- ─── 4. RLS ───────────────────────────────────────────────────────
-- SELECT only — no INSERT/UPDATE/DELETE policy on either new table;
-- every mutation goes exclusively through create_recurring_meeting()
-- below (meeting_series_exceptions has no write path at all yet).
-- No change to meetings_select/meeting_participants_select —
-- occurrences are ordinary rows, already correctly governed
-- (see this file's own header note).
ALTER TABLE meeting_series             ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_series_exceptions  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "meeting_series_select" ON meeting_series;
CREATE POLICY "meeting_series_select" ON meeting_series
  FOR SELECT USING (
    is_super_admin() OR (current_user_module_enabled('meetings') AND organization_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "meeting_series_exceptions_select" ON meeting_series_exceptions;
CREATE POLICY "meeting_series_exceptions_select" ON meeting_series_exceptions
  FOR SELECT USING (
    is_super_admin() OR EXISTS (
      SELECT 1 FROM meeting_series s
      WHERE s.id = meeting_series_exceptions.series_id
        AND current_user_module_enabled('meetings') AND s.organization_id = get_my_org_id()
    )
  );

-- ─── 5. update_meeting(): series_detached bookkeeping ────────────
-- Body-only change, no signature change. Fires unconditionally
-- whenever the row being updated belongs to a series, regardless of
-- WHICH fields were actually changed in this call — a deliberate
-- choice per docs/23 §Phase F/§12's explicit warning that this field
-- is "easy to get subtly wrong... must fire on every field-changing
-- path through update_meeting(), not just some." Computed once
-- before the UPDATE and applied via CASE so a non-recurring meeting
-- (series_id IS NULL) is never touched — series_detached stays FALSE
-- for it forever, exactly as it already is by column default.
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
  ELSIF v_meaningful_change THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_updated', 'meeting', p_meeting_id, 'A meeting you are part of was updated.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. create_recurring_meeting() ───────────────────────────────
-- Single SECURITY DEFINER transaction. Generates every occurrence
-- date server-side (index-based from series_start_date, never
-- incremental from the previous occurrence — incremental stepping
-- would silently "drift" a monthly series anchored on day 31 after
-- Postgres clamps a short month, e.g. Jan 31 -> Feb 29 -> (wrongly)
-- Mar 29 instead of Mar 31; computing every date as
-- series_start_date + N*interval directly from the ORIGINAL start
-- avoids this entirely). Each occurrence is created by calling the
-- existing, completely unmodified create_meeting() — not duplicated
-- insert logic — then stamped with series_id/series_occurrence_date.
-- If a room is requested, assign_room_booking() (existing, unmodified)
-- is called per occurrence inside this same transaction: any single
-- occurrence's room conflict raises an exception that propagates out
-- and aborts the ENTIRE transaction, rolling back every occurrence
-- already inserted in this call — deliberate all-or-nothing safety,
-- achieved for free by ordinary Postgres transaction semantics, no
-- special rollback code needed. If a group is requested,
-- add_group_as_participants() (existing, unmodified) is called per
-- occurrence after the room, applying the group's CURRENT membership
-- to every occurrence at creation time only — never a stored,
-- ongoing link (later group edits never retroactively change any
-- already-created occurrence, exactly like applying a group to a
-- single ordinary meeting).
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
  p_interval_count INTEGER DEFAULT 1
) RETURNS TABLE (series_id UUID, meeting_id UUID, occurrence_date DATE) AS $$
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
  -- Occurrence-count safety cap, checked up front against the date
  -- range directly — protects against a pathological request (e.g. a
  -- multi-decade weekly series) without needing to run the loop first.
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
      PERFORM assign_room_booking(v_meeting_id, p_room_id);
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

  -- One notification to the creator confirming series creation — not
  -- one per occurrence, which would be spammy for a multi-month
  -- weekly series (docs/23 §Phase F/§7's explicit design). Each
  -- occurrence's own create_meeting() call fires zero notifications
  -- (matching a single ordinary meeting's own creation, which never
  -- notifies anyone either); each group member addition, if a group
  -- was supplied, fires the existing per-member participant_added
  -- notification unchanged, same as applying a group to any single
  -- ordinary meeting.
  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (v_actor, 'meeting_series_created', 'meeting_series', v_series_id,
    v_occurrence_count || ' occurrences were created for "' || p_title || '".');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. audit_logs / notifications CHECK extensions ─────────────
-- Full accumulated lists restated (per docs/23 §0's coordination
-- note), not a bare addition.
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
    'meeting_series_created'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group',
    'meeting_series'
  ));

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
    'room_assigned', 'meeting_cancelled', 'participant_removed',
    'participant_responded',
    'meeting_series_created'
  ));

COMMIT;
