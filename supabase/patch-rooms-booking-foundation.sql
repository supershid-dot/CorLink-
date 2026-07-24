-- ============================================================
-- CorLink — Rooms and Booking Database Foundation
-- Phase 4 (docs/03 §8) — implements docs/09-rooms-booking-v1-decisions.md
-- and docs/10-rooms-booking-technical-readiness.md exactly.
--
-- Creates: meeting_rooms, meeting_room_managers, meeting_room_blocks,
-- meeting_room_bookings. Hybrid conflict prevention (btree_gist
-- exclusion constraint + trigger). 9 mutating RPCs + 1 read RPC.
-- SELECT-only RLS on the two conflict-sensitive tables (bookings,
-- blocks); normal role-gated RLS on rooms/managers. Extends
-- audit_logs/notifications CHECK constraints. No Meetings objects,
-- no recurring bookings, no attachments on rooms/bookings, no
-- Telegram. Idempotent — safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. Extension ───────────────────────────────────────────
-- Additive only — no interaction with pgcrypto/pg_cron (docs/10 §2).
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ─── 2. meeting_rooms ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_rooms (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name           TEXT        NOT NULL,
  capacity       INTEGER,
  bookable_until TIME,
  is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by     UUID        NOT NULL REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_meeting_rooms_org ON meeting_rooms(org_id);

DROP TRIGGER IF EXISTS set_updated_at ON meeting_rooms;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_rooms
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 3. meeting_room_managers (docs/09 §4 / docs/10 §8 Option D) ──
-- Additive-only grant: never restricts, only adds a non-supervisor
-- manager for one specific room. Org-wide supervisors/admins already
-- manage every room in their own org automatically (is_room_manager()
-- below) — most rooms are expected to have zero rows here.
CREATE TABLE IF NOT EXISTS meeting_room_managers (
  room_id     UUID        NOT NULL REFERENCES meeting_rooms(id) ON DELETE CASCADE,
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  assigned_by UUID        NOT NULL REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (room_id, user_id)
);

-- ─── 4. meeting_room_blocks (docs/09 §9 / docs/10 §16) ────────
CREATE TABLE IF NOT EXISTS meeting_room_blocks (
  id                                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id                                UUID        NOT NULL REFERENCES meeting_rooms(id) ON DELETE CASCADE,
  start_at                               TIMESTAMPTZ NOT NULL,
  end_at                                 TIMESTAMPTZ NOT NULL,
  reason                                 TEXT        NOT NULL,
  is_active                              BOOLEAN     NOT NULL DEFAULT TRUE,
  conflict_override                      BOOLEAN     NOT NULL DEFAULT FALSE,
  conflict_override_reason               TEXT,
  conflict_overridden_by                 UUID        REFERENCES users(id),
  conflict_overridden_at                 TIMESTAMPTZ,
  conflict_override_impacted_booking_ids UUID[],
  created_by                             UUID        NOT NULL REFERENCES users(id),
  created_at                             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_room_blocks_range_check CHECK (end_at > start_at),
  CONSTRAINT meeting_room_blocks_reason_check CHECK (btrim(reason) <> ''),
  CONSTRAINT meeting_room_blocks_override_reason_check
    CHECK (NOT conflict_override OR conflict_override_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_meeting_room_blocks_room ON meeting_room_blocks(room_id);
CREATE INDEX IF NOT EXISTS idx_meeting_room_blocks_active ON meeting_room_blocks(room_id) WHERE is_active = TRUE;

DROP TRIGGER IF EXISTS set_updated_at ON meeting_room_blocks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_room_blocks
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 5. meeting_room_bookings (docs/09 §1-§3 / docs/10 §16) ───
-- meeting_id is deliberately nullable with NO FK — the meetings table
-- does not exist yet (a separate, later, explicitly-authorized phase
-- per docs/10 §17 step 5 / §20 item 5). Not ON DELETE CASCADE from
-- meeting_rooms — a room with booking history must not be silently
-- deletable; room retirement is meeting_rooms.is_active = FALSE.
CREATE TABLE IF NOT EXISTS meeting_room_bookings (
  id                        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                    UUID        NOT NULL REFERENCES organizations(id),
  room_id                   UUID        NOT NULL REFERENCES meeting_rooms(id),
  meeting_id                UUID,
  section_id                UUID        REFERENCES sections(id),
  status                    TEXT        NOT NULL CHECK (status IN (
                               'hold', 'pending', 'confirmed', 'rejected',
                               'cancelled', 'expired', 'completed'
                             )),
  start_at                  TIMESTAMPTZ NOT NULL,
  end_at                    TIMESTAMPTZ NOT NULL,
  timezone                  TEXT        NOT NULL DEFAULT 'Indian/Maldives',
  expires_at                TIMESTAMPTZ,
  created_by                UUID        NOT NULL REFERENCES users(id),
  approved_by               UUID        REFERENCES users(id),
  approved_at               TIMESTAMPTZ,
  rejected_by               UUID        REFERENCES users(id),
  rejected_at                TIMESTAMPTZ,
  cancelled_by              UUID        REFERENCES users(id),
  cancelled_at              TIMESTAMPTZ,
  cancellation_reason       TEXT,
  conflict_override         BOOLEAN     NOT NULL DEFAULT FALSE,
  conflict_override_reason  TEXT,
  conflict_overridden_by    UUID        REFERENCES users(id),
  conflict_overridden_at    TIMESTAMPTZ,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_room_bookings_range_check CHECK (end_at > start_at),
  CONSTRAINT meeting_room_bookings_hold_expiry_check
    CHECK (status <> 'hold' OR expires_at IS NOT NULL),
  CONSTRAINT meeting_room_bookings_override_reason_check
    CHECK (NOT conflict_override OR conflict_override_reason IS NOT NULL),
  -- One-directional: a row that later moves past confirmed/rejected/
  -- cancelled legitimately keeps that state's actor/timestamp as
  -- history, so these only constrain the row while IN that status.
  CONSTRAINT meeting_room_bookings_approved_check
    CHECK (status <> 'confirmed' OR approved_by IS NOT NULL),
  CONSTRAINT meeting_room_bookings_rejected_check
    CHECK (status <> 'rejected' OR rejected_by IS NOT NULL),
  CONSTRAINT meeting_room_bookings_cancelled_check
    CHECK (status <> 'cancelled' OR (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_meeting_room_bookings_room ON meeting_room_bookings(room_id);
CREATE INDEX IF NOT EXISTS idx_meeting_room_bookings_org ON meeting_room_bookings(org_id);
CREATE INDEX IF NOT EXISTS idx_meeting_room_bookings_created_by ON meeting_room_bookings(created_by);
CREATE INDEX IF NOT EXISTS idx_meeting_room_bookings_meeting ON meeting_room_bookings(meeting_id) WHERE meeting_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_meeting_room_bookings_blocking
  ON meeting_room_bookings(room_id, start_at, end_at) WHERE status IN ('hold', 'pending', 'confirmed');

DROP TRIGGER IF EXISTS set_updated_at ON meeting_room_bookings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_room_bookings
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 6. Helper functions ───────────────────────────────────────

-- Advisory-lock key for a room, keyed by its UUID text (docs/10 §4).
CREATE OR REPLACE FUNCTION room_lock_key(p_room_id UUID)
RETURNS BIGINT AS $$
  SELECT hashtext(p_room_id::text)::bigint;
$$ LANGUAGE sql IMMUTABLE;

-- Both module-enablement layers (docs/09 §4 Layer 1) composed once.
CREATE OR REPLACE FUNCTION rooms_module_active_for(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_module_active('rooms') AND module_enabled_for_org(p_org_id, 'rooms');
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- docs/09 §4 Layer 2 / docs/10 §8 Option D: super admin, OR an
-- org-wide supervisor/admin of the room's own org (role held in ANY
-- active assignment — deliberately not scoped to a particular
-- section, per docs/10 §8's "org's supervisors/admins manage every
-- room their own org owns, automatically"), OR an explicit
-- meeting_room_managers grant for this specific room.
CREATE OR REPLACE FUNCTION is_room_manager(p_room_id UUID, p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN AS $$
  SELECT
    p_user_id IS NOT NULL
    AND (
      COALESCE((SELECT is_super_admin FROM users WHERE id = p_user_id), FALSE)
      OR EXISTS (
        SELECT 1
        FROM meeting_rooms r
        JOIN users u ON u.id = p_user_id
        JOIN user_assignments ua ON ua.user_id = p_user_id AND ua.is_active = TRUE
        WHERE r.id = p_room_id
          AND r.org_id = u.org_id
          AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
      )
      OR EXISTS (
        SELECT 1 FROM meeting_room_managers mrm
        WHERE mrm.room_id = p_room_id AND mrm.user_id = p_user_id
      )
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Recipients for room-manager-directed notifications (docs/10 §11):
-- every org-wide supervisor/admin of the room's org, plus any
-- explicit per-room manager grant, deduplicated.
CREATE OR REPLACE FUNCTION room_manager_recipient_ids(p_room_id UUID, p_exclude UUID DEFAULT NULL)
RETURNS SETOF UUID AS $$
  SELECT DISTINCT uid FROM (
    SELECT ua.user_id AS uid
    FROM user_assignments ua
    JOIN users u ON u.id = ua.user_id
    JOIN meeting_rooms r ON r.org_id = u.org_id
    WHERE r.id = p_room_id AND ua.is_active = TRUE
      AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
    UNION
    SELECT mrm.user_id AS uid
    FROM meeting_room_managers mrm
    WHERE mrm.room_id = p_room_id
  ) recipients
  WHERE p_exclude IS NULL OR uid <> p_exclude;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Derived-only "completed" projection (docs/10 §6) — never written to
-- the status column; no pg_cron job exists for this.
CREATE OR REPLACE FUNCTION booking_effective_status(p_status TEXT, p_end_at TIMESTAMPTZ)
RETURNS TEXT AS $$
  SELECT CASE WHEN p_status = 'confirmed' AND p_end_at < now() THEN 'completed' ELSE p_status END;
$$ LANGUAGE sql STABLE;

-- ─── 7. Status-transition enforcement (docs/09 §3) ────────────
CREATE OR REPLACE FUNCTION valid_booking_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('hold', 'pending'), ('hold', 'confirmed'), ('hold', 'cancelled'), ('hold', 'expired'),
    ('pending', 'confirmed'), ('pending', 'rejected'), ('pending', 'cancelled'),
    ('confirmed', 'cancelled'), ('confirmed', 'completed')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_booking_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_booking_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid booking status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_booking_status ON meeting_room_bookings;
CREATE TRIGGER check_booking_status BEFORE UPDATE OF status ON meeting_room_bookings
  FOR EACH ROW EXECUTE FUNCTION trigger_check_booking_status();

-- ─── 8. Conflict prevention (docs/09 §7 / docs/10 §4) ─────────
-- Primary safety net: Postgres-enforced exclusion constraint over the
-- two statuses whose blocking-ness has no time-dependent condition.
-- Immune to any application bug or direct-API bypass.
ALTER TABLE meeting_room_bookings DROP CONSTRAINT IF EXISTS meeting_room_bookings_no_overlap;
ALTER TABLE meeting_room_bookings
  ADD CONSTRAINT meeting_room_bookings_no_overlap
  EXCLUDE USING gist (
    room_id WITH =,
    tstzrange(start_at, end_at, '[)') WITH &&
  ) WHERE (status IN ('pending', 'confirmed') AND NOT conflict_override);

-- Covers everything the exclusion constraint structurally cannot:
-- holds (time-dependent expiry), cross-table room-block conflicts,
-- and the override escape hatch. Fires on every write that could
-- change what a row blocks — a bare timezone-only UPDATE does NOT
-- fire this (only room_id/start_at/end_at/status are watched), a
-- narrow, known, non-exploitable gap since meeting_room_bookings has
-- no direct-write RLS policy for any ordinary role (§14/§9 below) —
-- see docs/11 for the full note.
CREATE OR REPLACE FUNCTION meeting_room_bookings_conflict_guard()
RETURNS TRIGGER AS $$
DECLARE
  v_has_conflict BOOLEAN := FALSE;
BEGIN
  IF NEW.end_at <= NEW.start_at THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;

  -- Lock ordering: ascending UUID-text order when two rooms are
  -- involved (a reassignment), to avoid deadlock against a concurrent
  -- transaction moving a different booking the other way.
  IF TG_OP = 'UPDATE' AND OLD.room_id IS DISTINCT FROM NEW.room_id THEN
    IF OLD.room_id::text < NEW.room_id::text THEN
      PERFORM pg_advisory_xact_lock(room_lock_key(OLD.room_id));
      PERFORM pg_advisory_xact_lock(room_lock_key(NEW.room_id));
    ELSE
      PERFORM pg_advisory_xact_lock(room_lock_key(NEW.room_id));
      PERFORM pg_advisory_xact_lock(room_lock_key(OLD.room_id));
    END IF;
  ELSE
    PERFORM pg_advisory_xact_lock(room_lock_key(NEW.room_id));
  END IF;

  -- Lazily expire this room's (and, on reassignment, the old room's)
  -- own stale holds before checking anything else (docs/09 §6).
  UPDATE meeting_room_bookings
    SET status = 'expired'
    WHERE room_id = NEW.room_id AND status = 'hold' AND expires_at < now() AND id <> NEW.id;
  IF TG_OP = 'UPDATE' AND OLD.room_id IS DISTINCT FROM NEW.room_id THEN
    UPDATE meeting_room_bookings
      SET status = 'expired'
      WHERE room_id = OLD.room_id AND status = 'hold' AND expires_at < now() AND id <> NEW.id;
  END IF;

  IF NEW.status IN ('hold', 'pending', 'confirmed') THEN
    -- Against other currently-blocking bookings for this room. Covers
    -- BOTH holds (outside the exclusion constraint's WHERE clause)
    -- AND pending/confirmed rows (the exclusion constraint is the
    -- primary enforcement for those, but the incoming row itself may
    -- be a 'hold' being checked against an already-committed
    -- pending/confirmed row, which the constraint's own WHERE filter
    -- never sees since it only fires when the constraint's own scope
    -- applies to the row being written).
    IF EXISTS (
      SELECT 1 FROM meeting_room_bookings b
      WHERE b.room_id = NEW.room_id
        AND b.id <> NEW.id
        AND (b.status IN ('pending', 'confirmed') OR (b.status = 'hold' AND b.expires_at >= now()))
        AND tstzrange(b.start_at, b.end_at, '[)') && tstzrange(NEW.start_at, NEW.end_at, '[)')
    ) THEN
      v_has_conflict := TRUE;
    END IF;

    -- Against active room blocks for this room.
    IF NOT v_has_conflict AND EXISTS (
      SELECT 1 FROM meeting_room_blocks blk
      WHERE blk.room_id = NEW.room_id
        AND blk.is_active = TRUE
        AND tstzrange(blk.start_at, blk.end_at, '[)') && tstzrange(NEW.start_at, NEW.end_at, '[)')
    ) THEN
      v_has_conflict := TRUE;
    END IF;

    IF v_has_conflict THEN
      -- Override escape hatch: only permitted when the transaction was
      -- explicitly flagged AND both override actor/reason fields are
      -- populated (set only by the authorized RPC path, never a bare
      -- client-settable parameter alone).
      IF current_setting('app.booking_override', true) = 'true'
         AND NEW.conflict_override_reason IS NOT NULL
         AND NEW.conflict_overridden_by IS NOT NULL THEN
        NEW.conflict_override := TRUE;
      ELSE
        RAISE EXCEPTION 'Booking conflict: room is already reserved or blocked for this time window';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS booking_conflict_guard ON meeting_room_bookings;
CREATE TRIGGER booking_conflict_guard
  BEFORE INSERT OR UPDATE OF room_id, start_at, end_at, status ON meeting_room_bookings
  FOR EACH ROW EXECUTE FUNCTION meeting_room_bookings_conflict_guard();

-- Reverse room-block conflict (docs/09 §16 item 4, resolved by docs/10
-- §5): a block cannot be created over an existing active booking
-- unless an authorized override is supplied — no booking row is ever
-- modified by this path (docs/10 §5 item 3).
CREATE OR REPLACE FUNCTION meeting_room_blocks_conflict_guard()
RETURNS TRIGGER AS $$
DECLARE
  v_impacted UUID[];
BEGIN
  IF NEW.end_at <= NEW.start_at THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;

  PERFORM pg_advisory_xact_lock(room_lock_key(NEW.room_id));

  UPDATE meeting_room_bookings
    SET status = 'expired'
    WHERE room_id = NEW.room_id AND status = 'hold' AND expires_at < now();

  SELECT array_agg(b.id) INTO v_impacted
  FROM meeting_room_bookings b
  WHERE b.room_id = NEW.room_id
    AND (b.status IN ('pending', 'confirmed') OR (b.status = 'hold' AND b.expires_at >= now()))
    AND tstzrange(b.start_at, b.end_at, '[)') && tstzrange(NEW.start_at, NEW.end_at, '[)');

  IF v_impacted IS NOT NULL THEN
    IF current_setting('app.booking_override', true) = 'true'
       AND NEW.conflict_override_reason IS NOT NULL
       AND NEW.conflict_overridden_by IS NOT NULL THEN
      NEW.conflict_override := TRUE;
      NEW.conflict_override_impacted_booking_ids := v_impacted;
    ELSE
      RAISE EXCEPTION 'Cannot create room block: % existing booking(s) overlap this window', array_length(v_impacted, 1);
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS block_conflict_guard ON meeting_room_blocks;
CREATE TRIGGER block_conflict_guard
  BEFORE INSERT ON meeting_room_blocks
  FOR EACH ROW EXECUTE FUNCTION meeting_room_blocks_conflict_guard();

-- ─── 9. Extend shared CHECK constraints (docs/10 §11/§12) ─────
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention'
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
    'rejected', 'rescheduled', 'conflict_overridden'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking'
  ));

-- ─── 10. RPCs (docs/10 §14) ────────────────────────────────────
-- All SECURITY DEFINER, search_path pinned, actor from auth.uid()
-- only (never a client-supplied identity), refuse a NULL actor
-- outright rather than let it evaluate to a silent NULL comparison.

CREATE OR REPLACE FUNCTION create_booking_hold(
  p_room_id UUID,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_meeting_id UUID DEFAULT NULL,
  p_section_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_actor_org UUID;
  v_booking_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_booking_hold requires an authenticated caller';
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

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT is_super_admin() AND v_actor_org <> v_room.org_id THEN
    RAISE EXCEPTION 'Cannot book a room outside your own organization';
  END IF;

  INSERT INTO meeting_room_bookings (
    org_id, room_id, meeting_id, section_id, status,
    start_at, end_at, timezone, expires_at, created_by
  ) VALUES (
    v_room.org_id, p_room_id, p_meeting_id, p_section_id, 'hold',
    p_start_at, p_end_at, p_timezone, now() + interval '10 minutes', v_actor
  ) RETURNING id INTO v_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting_room_booking', v_booking_id);

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION submit_booking_request(
  p_room_id UUID DEFAULT NULL,
  p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_meeting_id UUID DEFAULT NULL,
  p_section_id UUID DEFAULT NULL,
  p_hold_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_actor_org UUID;
  v_hold meeting_room_bookings;
  v_booking_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_booking_request requires an authenticated caller';
  END IF;

  IF p_hold_id IS NOT NULL THEN
    SELECT * INTO v_hold FROM meeting_room_bookings WHERE id = p_hold_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Hold not found';
    END IF;
    IF v_hold.created_by <> v_actor THEN
      RAISE EXCEPTION 'Not authorized to submit this hold';
    END IF;
    IF v_hold.status <> 'hold' THEN
      RAISE EXCEPTION 'Booking is not a hold (status: %)', v_hold.status;
    END IF;
    IF v_hold.expires_at < now() THEN
      RAISE EXCEPTION 'This hold has expired; create a new booking request';
    END IF;

    UPDATE meeting_room_bookings SET status = 'pending' WHERE id = p_hold_id;
    v_booking_id := p_hold_id;

    SELECT * INTO v_room FROM meeting_rooms WHERE id = v_hold.room_id;
  ELSE
    IF p_room_id IS NULL OR p_start_at IS NULL OR p_end_at IS NULL THEN
      RAISE EXCEPTION 'room_id, start_at, and end_at are required when not converting a hold';
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

    SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
    IF v_actor_org IS NULL THEN
      RAISE EXCEPTION 'Caller account not found or inactive';
    END IF;
    IF NOT is_super_admin() AND v_actor_org <> v_room.org_id THEN
      RAISE EXCEPTION 'Cannot book a room outside your own organization';
    END IF;

    INSERT INTO meeting_room_bookings (
      org_id, room_id, meeting_id, section_id, status,
      start_at, end_at, timezone, created_by
    ) VALUES (
      v_room.org_id, p_room_id, p_meeting_id, p_section_id, 'pending',
      p_start_at, p_end_at, p_timezone, v_actor
    ) RETURNING id INTO v_booking_id;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'submitted', 'meeting_room_booking', v_booking_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'booking_submitted', 'meeting_room_booking', v_booking_id,
    'A new room booking request is awaiting your decision.'
  FROM room_manager_recipient_ids(v_room.id, v_actor) AS uid;

  RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION create_room_booking(
  p_room_id UUID,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_timezone TEXT DEFAULT 'Indian/Maldives',
  p_meeting_id UUID DEFAULT NULL,
  p_section_id UUID DEFAULT NULL
) RETURNS UUID AS $$
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

CREATE OR REPLACE FUNCTION approve_booking(
  p_booking_id UUID,
  p_override_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF v_booking.status = 'hold' THEN
    IF v_booking.expires_at < now() THEN
      RAISE EXCEPTION 'Cannot approve: this hold has expired';
    END IF;
  ELSIF v_booking.status <> 'pending' THEN
    RAISE EXCEPTION 'Booking is not awaiting approval (status: %)', v_booking.status;
  END IF;

  -- Self-approval prevention (docs/09 §4/§15, docs/10 §9) —
  -- unconditional on identity, applies even if the actor also passes
  -- is_room_manager()/is_admin(). The only bypass is an explicit,
  -- audited super-admin override with a mandatory reason.
  IF v_booking.created_by = v_actor THEN
    IF NOT (is_super_admin() AND p_override_reason IS NOT NULL) THEN
      RAISE EXCEPTION 'Cannot approve your own booking request';
    END IF;
  END IF;

  IF NOT (is_room_manager(v_booking.room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to approve this booking';
  END IF;

  IF p_override_reason IS NOT NULL THEN
    PERFORM set_config('app.booking_override', 'true', true);
    UPDATE meeting_room_bookings
      SET status = 'confirmed', approved_by = v_actor, approved_at = now(),
          conflict_override_reason = p_override_reason,
          conflict_overridden_by = v_actor, conflict_overridden_at = now()
      WHERE id = p_booking_id;
    PERFORM set_config('app.booking_override', 'false', true);

    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
    VALUES (v_actor, 'conflict_overridden', 'meeting_room_booking', p_booking_id, p_override_reason);
  ELSE
    UPDATE meeting_room_bookings
      SET status = 'confirmed', approved_by = v_actor, approved_at = now()
      WHERE id = p_booking_id;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'approved', 'meeting_room_booking', p_booking_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (v_booking.created_by, 'booking_approved', 'meeting_room_booking', p_booking_id,
    'Your room booking request has been approved.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION reject_booking(
  p_booking_id UUID,
  p_rejection_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reject_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  IF v_booking.status <> 'pending' THEN
    RAISE EXCEPTION 'Only a pending booking can be rejected (status: %)', v_booking.status;
  END IF;
  IF NOT (is_room_manager(v_booking.room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to reject this booking';
  END IF;

  UPDATE meeting_room_bookings
    SET status = 'rejected', rejected_by = v_actor, rejected_at = now()
    WHERE id = p_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'rejected', 'meeting_room_booking', p_booking_id, p_rejection_reason);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (v_booking.created_by, 'booking_rejected', 'meeting_room_booking', p_booking_id,
    'Your room booking request has been rejected.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION cancel_booking(
  p_booking_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
  v_is_manager BOOLEAN;
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

  v_is_manager := is_room_manager(v_booking.room_id, v_actor) OR is_admin();

  -- Creator cancelling their OWN booking never needs a reason, even if
  -- they also happen to hold manager/admin authority for the room —
  -- the mandatory-reason rule is specifically for a manager/admin
  -- acting on someone ELSE's booking, so this branch must be checked
  -- first regardless of v_is_manager.
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

CREATE OR REPLACE FUNCTION reschedule_booking(
  p_booking_id UUID,
  p_new_room_id UUID DEFAULT NULL,
  p_new_start_at TIMESTAMPTZ DEFAULT NULL,
  p_new_end_at TIMESTAMPTZ DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
  v_new_room meeting_rooms;
  v_new_room_id UUID;
  v_new_start TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
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
    SET room_id = v_new_room_id, start_at = v_new_start, end_at = v_new_end
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

CREATE OR REPLACE FUNCTION create_room_block(
  p_room_id UUID,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_reason TEXT,
  p_override_reason TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_block_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_room_block requires an authenticated caller';
  END IF;
  IF p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required to block a room';
  END IF;

  SELECT * INTO v_room FROM meeting_rooms WHERE id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found';
  END IF;
  IF NOT rooms_module_active_for(v_room.org_id) THEN
    RAISE EXCEPTION 'The Rooms module is not enabled for this organization';
  END IF;
  IF NOT (is_room_manager(p_room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to block this room';
  END IF;

  IF p_override_reason IS NOT NULL THEN
    PERFORM set_config('app.booking_override', 'true', true);
    INSERT INTO meeting_room_blocks (
      room_id, start_at, end_at, reason, created_by,
      conflict_override_reason, conflict_overridden_by, conflict_overridden_at
    ) VALUES (
      p_room_id, p_start_at, p_end_at, p_reason, v_actor,
      p_override_reason, v_actor, now()
    ) RETURNING id INTO v_block_id;
    PERFORM set_config('app.booking_override', 'false', true);

    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
    VALUES (v_actor, 'conflict_overridden', 'meeting_room_block', v_block_id, p_override_reason);
  ELSE
    INSERT INTO meeting_room_blocks (room_id, start_at, end_at, reason, created_by)
    VALUES (p_room_id, p_start_at, p_end_at, p_reason, v_actor)
    RETURNING id INTO v_block_id;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'created', 'meeting_room_block', v_block_id);

  RETURN v_block_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION cancel_room_block(
  p_block_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_block meeting_room_blocks;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_room_block requires an authenticated caller';
  END IF;

  SELECT * INTO v_block FROM meeting_room_blocks WHERE id = p_block_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room block not found';
  END IF;
  IF NOT v_block.is_active THEN
    RAISE EXCEPTION 'This room block is already inactive';
  END IF;
  IF NOT (is_room_manager(v_block.room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to cancel this room block';
  END IF;

  UPDATE meeting_room_blocks SET is_active = FALSE WHERE id = p_block_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting_room_block', p_block_id, p_reason);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Read-only convenience RPC (docs/10 §14) — any module-enabled org
-- member may check a room's availability for a window.
CREATE OR REPLACE FUNCTION check_room_availability(
  p_room_id UUID,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ
) RETURNS BOOLEAN AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_room meeting_rooms;
  v_actor_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'check_room_availability requires an authenticated caller';
  END IF;

  SELECT * INTO v_room FROM meeting_rooms WHERE id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found';
  END IF;
  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor;
  IF NOT is_super_admin() AND v_actor_org <> v_room.org_id THEN
    RAISE EXCEPTION 'Cannot check availability for a room outside your own organization';
  END IF;

  RETURN NOT EXISTS (
    SELECT 1 FROM meeting_room_bookings b
    WHERE b.room_id = p_room_id
      AND (b.status IN ('pending', 'confirmed') OR (b.status = 'hold' AND b.expires_at >= now()))
      AND tstzrange(b.start_at, b.end_at, '[)') && tstzrange(p_start_at, p_end_at, '[)')
  ) AND NOT EXISTS (
    SELECT 1 FROM meeting_room_blocks blk
    WHERE blk.room_id = p_room_id AND blk.is_active = TRUE
      AND tstzrange(blk.start_at, blk.end_at, '[)') && tstzrange(p_start_at, p_end_at, '[)')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 11. RLS (docs/10 §15) ─────────────────────────────────────
ALTER TABLE meeting_rooms         ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_room_managers ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_room_blocks   ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_room_bookings ENABLE ROW LEVEL SECURITY;

-- meeting_rooms — org-wide read within the owning org (a room's
-- name/capacity is not sensitive), full write for org supervisors/
-- admins. No DELETE policy — deactivate via is_active, matching the
-- existing commands/departments/divisions/sections convention (no
-- hard delete in normal workflows, docs/09 §15).
DROP POLICY IF EXISTS "meeting_rooms_select" ON meeting_rooms;
CREATE POLICY "meeting_rooms_select" ON meeting_rooms
  FOR SELECT USING (
    is_super_admin() OR (org_id = get_my_org_id() AND current_user_module_enabled('rooms'))
  );

DROP POLICY IF EXISTS "meeting_rooms_insert" ON meeting_rooms;
CREATE POLICY "meeting_rooms_insert" ON meeting_rooms
  FOR INSERT WITH CHECK (
    is_super_admin()
    OR (org_id = get_my_org_id() AND is_supervisor_or_above() AND current_user_module_enabled('rooms'))
  );

DROP POLICY IF EXISTS "meeting_rooms_update" ON meeting_rooms;
CREATE POLICY "meeting_rooms_update" ON meeting_rooms
  FOR UPDATE USING (
    is_super_admin()
    OR (org_id = get_my_org_id() AND is_supervisor_or_above() AND current_user_module_enabled('rooms'))
  );

-- meeting_room_managers — a simple assignment join table, same
-- direct-write shape as entry_sections/user_assignments: org
-- supervisors/admins (or super admins) may grant/revoke a specific
-- non-supervisor manager for a room they already manage. WITH CHECK
-- enforces the manager grant's target user shares the room's org.
DROP POLICY IF EXISTS "meeting_room_managers_select" ON meeting_room_managers;
CREATE POLICY "meeting_room_managers_select" ON meeting_room_managers
  FOR SELECT USING (
    is_super_admin()
    OR EXISTS (SELECT 1 FROM meeting_rooms r WHERE r.id = room_id AND r.org_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "meeting_room_managers_insert" ON meeting_room_managers;
CREATE POLICY "meeting_room_managers_insert" ON meeting_room_managers
  FOR INSERT WITH CHECK (
    (is_super_admin() OR is_room_manager(room_id))
    AND EXISTS (
      SELECT 1 FROM meeting_rooms r JOIN users u ON u.id = meeting_room_managers.user_id
      WHERE r.id = room_id AND r.org_id = u.org_id
    )
  );

DROP POLICY IF EXISTS "meeting_room_managers_delete" ON meeting_room_managers;
CREATE POLICY "meeting_room_managers_delete" ON meeting_room_managers
  FOR DELETE USING (is_super_admin() OR is_room_manager(room_id));

-- meeting_room_bookings / meeting_room_blocks — SELECT only. No
-- INSERT/UPDATE/DELETE policy exists for any role; every mutation
-- goes exclusively through the SECURITY DEFINER RPCs above, which
-- bypass RLS internally. A direct REST call against either table is
-- rejected outright by RLS regardless of the caller's role (docs/09
-- §15, docs/10 §14/§18 test 15).
DROP POLICY IF EXISTS "meeting_room_bookings_select" ON meeting_room_bookings;
CREATE POLICY "meeting_room_bookings_select" ON meeting_room_bookings
  FOR SELECT USING (
    is_super_admin()
    OR (
      current_user_module_enabled('rooms')
      AND (org_id = get_my_org_id() OR is_room_manager(room_id) OR created_by = auth.uid())
    )
  );

DROP POLICY IF EXISTS "meeting_room_blocks_select" ON meeting_room_blocks;
CREATE POLICY "meeting_room_blocks_select" ON meeting_room_blocks
  FOR SELECT USING (
    is_super_admin()
    OR (
      current_user_module_enabled('rooms')
      AND EXISTS (SELECT 1 FROM meeting_rooms r WHERE r.id = room_id AND r.org_id = get_my_org_id())
    )
  );

COMMIT;
