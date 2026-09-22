-- Rollback for patch-calendar-staff-own-org-only.sql (142).
-- Restores viewable_calendar_staff() to its pre-142 body (docs/137's
-- patch-calendar-staff-schedule-access.sql), which lists every active
-- user across every organization for a super admin caller.

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
