-- 137: Calendar tab — view a specific staff member's own schedule.
--
-- UAT (MeetFlow parity, screenshots of MeetFlow's Calendar staff
-- picker + its per-user "CAN VIEW SCHEDULE OF" admin permission
-- checklist): "in calendar tab should be able to see the schedule of
-- the staff when selected, by default it shows all the meeting
-- scheduled. the section staff can see all the staff in that section,
-- department or command and the staff who is approved by the admin in
-- admin portal".
--
-- CalendarAPI's own header comment (js/data/calendar-api.js) states
-- the deliberate prior design: Calendar never issues a new SECURITY
-- DEFINER read — every event it shows is one the caller could already
-- see by querying Meetings/Rooms directly, and "show me user X's
-- schedule" was explicitly called out there as a correctness gap this
-- file avoided rather than solved (RLS on meeting_participants only
-- grants a caller their OWN row or a meeting they manage — querying
-- for an arbitrary other user's participant rows would silently return
-- an incomplete result once that other user has meetings outside the
-- caller's own visibility). This migration is the first time CorLink
-- deliberately crosses that boundary, on purpose, behind an explicit
-- new permission check — not a query-shape workaround.
--
-- ── Who may view whose schedule ───────────────────────────────────
-- can_view_user_schedule(target) is TRUE when the caller is:
--   1. the target themselves;
--   2. a super admin (any org);
--   3. an org admin, for any active user in their own org;
--   4. a "colleague" of the target — the target holds an active
--      user_assignments row whose scope (section/department/division/
--      command/organization, via the existing scope_section_ids())
--      overlaps the caller's own my_section_ids() — i.e. literally
--      "staff in that section, department or command" from the UAT;
--   5. explicitly granted access via the new user_schedule_grants
--      table — "the staff who is approved by the admin in admin
--      portal", set by an org admin per-viewer from the Manage User
--      panel (mirrors MeetFlow's own per-user "CAN VIEW SCHEDULE OF"
--      checklist).
--
-- viewable_calendar_staff() lists exactly the staff a caller is
-- allowed to pick in the Calendar tab's new staff selector (built
-- from the same predicate, so the picker's contents and what it's
-- actually allowed to fetch never drift apart). fetch_user_calendar_
-- events() is the actual cross-user read, gated by the same check,
-- SECURITY DEFINER so it can see the target's meetings even where the
-- caller's own RLS-scoped read would have missed them — deliberately
-- narrow: only meetings (as creator or active participant) in the
-- requested range, nothing about rooms/leave/other modules.

-- ── user_schedule_grants ──────────────────────────────────────────
-- No direct INSERT/UPDATE/DELETE policy — every write goes through
-- admin_set_schedule_grants() (SECURITY DEFINER), the same "RPC-only
-- mutation" convention meetings/meeting_participants already use
-- (docs/12 §18) rather than relying on a hand-written RLS write
-- policy for a table that is itself an access-control list.
CREATE TABLE IF NOT EXISTS user_schedule_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  viewer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  granted_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (viewer_id, target_user_id),
  CHECK (viewer_id <> target_user_id)
);

ALTER TABLE user_schedule_grants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_schedule_grants_select ON user_schedule_grants;
CREATE POLICY user_schedule_grants_select ON user_schedule_grants FOR SELECT
  USING (
    viewer_id = auth.uid()
    OR is_super_admin()
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_schedule_grants.viewer_id AND u.org_id = get_my_org_id() AND is_admin()
    )
  );

-- ── can_view_user_schedule() ──────────────────────────────────────
CREATE OR REPLACE FUNCTION can_view_user_schedule(p_target_user_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_org UUID;
  v_target_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RETURN FALSE;
  END IF;
  IF p_target_user_id = v_actor THEN
    RETURN TRUE;
  END IF;
  IF is_super_admin() THEN
    RETURN TRUE;
  END IF;

  v_org := get_my_org_id();
  SELECT org_id INTO v_target_org FROM users WHERE id = p_target_user_id AND is_active = TRUE;
  IF v_target_org IS NULL OR v_target_org <> v_org THEN
    RETURN FALSE;
  END IF;

  IF is_admin() THEN
    RETURN TRUE;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM user_assignments ua
    CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
    WHERE ua.user_id = p_target_user_id AND ua.is_active = TRUE AND sid IN (SELECT my_section_ids())
  ) OR EXISTS (
    SELECT 1 FROM user_schedule_grants g WHERE g.viewer_id = v_actor AND g.target_user_id = p_target_user_id
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION can_view_user_schedule(UUID) TO authenticated;

-- ── viewable_calendar_staff() ──────────────────────────────────────
CREATE OR REPLACE FUNCTION viewable_calendar_staff()
RETURNS TABLE(id UUID, full_name TEXT, service_number TEXT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'viewable_calendar_staff requires an authenticated caller';
  END IF;

  IF is_super_admin() THEN
    RETURN QUERY
      SELECT u.id, u.full_name, u.service_number FROM users u
      WHERE u.is_active = TRUE AND u.id <> v_actor
      ORDER BY u.full_name;
    RETURN;
  END IF;

  v_org := get_my_org_id();
  RETURN QUERY
    SELECT u.id, u.full_name, u.service_number FROM users u
    WHERE u.org_id = v_org AND u.is_active = TRUE AND u.id <> v_actor
      AND can_view_user_schedule(u.id)
    ORDER BY u.full_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION viewable_calendar_staff() TO authenticated;

-- ── fetch_user_calendar_events() ──────────────────────────────────
-- Deliberately narrow: meetings only (as creator or active
-- participant), each meeting's currently-active room booking if any.
-- No standalone room bookings, no room blocks, no other module's
-- data — this is "this person's meeting schedule", not a general
-- cross-user data-access RPC.
CREATE OR REPLACE FUNCTION fetch_user_calendar_events(p_user_id UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
  id UUID, title TEXT, start_at TIMESTAMPTZ, end_at TIMESTAMPTZ, status TEXT,
  meeting_type TEXT, organization_id UUID, created_by UUID, created_by_name TEXT,
  series_id UUID, is_locked BOOLEAN, location_mode TEXT, room_id UUID, room_name TEXT
) AS $$
BEGIN
  IF NOT can_view_user_schedule(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized to view this user''s schedule';
  END IF;

  RETURN QUERY
  SELECT
    m.id, m.title, m.start_at, m.end_at, m.status, m.meeting_type,
    m.organization_id, m.created_by, cu.full_name,
    m.series_id, m.is_locked, m.location_mode,
    ab.room_id, ab.room_name
  FROM meetings m
  JOIN users cu ON cu.id = m.created_by
  LEFT JOIN LATERAL (
    SELECT b.room_id, r.name AS room_name
    FROM meeting_room_bookings b
    JOIN meeting_rooms r ON r.id = b.room_id
    WHERE b.meeting_id = m.id AND b.status IN ('hold', 'pending', 'confirmed')
    LIMIT 1
  ) ab ON TRUE
  WHERE m.start_at < p_to AND m.end_at > p_from
    AND (
      m.created_by = p_user_id
      OR EXISTS (
        SELECT 1 FROM meeting_participants mp
        WHERE mp.meeting_id = m.id AND mp.user_id = p_user_id AND mp.removed_at IS NULL
      )
    )
  ORDER BY m.start_at;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION fetch_user_calendar_events(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

-- ── admin_set_schedule_grants() ────────────────────────────────────
-- Full replace, matching the Manage User panel's checklist UX (save
-- the entire selected set at once) rather than incremental add/remove
-- calls.
CREATE OR REPLACE FUNCTION admin_set_schedule_grants(p_viewer_user_id UUID, p_target_user_ids UUID[])
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_viewer_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'admin_set_schedule_grants requires an authenticated caller';
  END IF;
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'Only an organization admin may manage schedule access grants';
  END IF;

  SELECT org_id INTO v_viewer_org FROM users WHERE id = p_viewer_user_id;
  IF v_viewer_org IS NULL OR (NOT is_super_admin() AND v_viewer_org <> get_my_org_id()) THEN
    RAISE EXCEPTION 'User not found or belongs to a different organization';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_target_user_ids, ARRAY[]::UUID[])) t(id)
    JOIN users u ON u.id = t.id
    WHERE u.org_id <> v_viewer_org
  ) THEN
    RAISE EXCEPTION 'Every granted target must belong to the same organization as the viewer';
  END IF;

  DELETE FROM user_schedule_grants WHERE viewer_id = p_viewer_user_id;
  INSERT INTO user_schedule_grants (viewer_id, target_user_id, granted_by)
  SELECT p_viewer_user_id, t.id, v_actor
  FROM unnest(COALESCE(p_target_user_ids, ARRAY[]::UUID[])) t(id)
  WHERE t.id <> p_viewer_user_id;
  -- No server-side audit_logs insert here — same convention as
  -- update_org_telegram_bot_token(), whose caller (AdminAPI) logs the
  -- audit entry client-side after a successful RPC call.
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION admin_set_schedule_grants(UUID, UUID[]) TO authenticated;
