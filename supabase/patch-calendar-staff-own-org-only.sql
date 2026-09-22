-- 142: Calendar's Staff filter only lists the caller's own organization.
--
-- UAT: "should only show staff who belong to the users organization"
-- (screenshot: the searchable Staff combobox, docs/141, listing staff
-- from more than one organization for a super admin caller).
--
-- viewable_calendar_staff() (docs/137) previously gave a super admin
-- every active user across every organization. Calendar's own event
-- feed was already forced to the caller's own org unconditionally in
-- docs/140 ("all organization filter is not needed, it should be
-- default to the users organization") — this closes the matching gap
-- in the Staff picker itself, so a super admin's Calendar experience
-- is org-scoped end to end, not just for the default event list.
--
-- Only viewable_calendar_staff() changes. can_view_user_schedule()
-- (still used by fetch_user_calendar_events() and reused here for the
-- colleague/explicit-grant check) is untouched — it's a general-
-- purpose permission check, not the listing itself, and nothing in the
-- UI can pass it a cross-org id anymore once this list no longer
-- offers one.

CREATE OR REPLACE FUNCTION viewable_calendar_staff()
RETURNS TABLE(id UUID, full_name TEXT, service_number TEXT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'viewable_calendar_staff requires an authenticated caller';
  END IF;

  v_org := get_my_org_id();
  RETURN QUERY
    SELECT u.id, u.full_name, u.service_number FROM users u
    WHERE u.org_id = v_org AND u.is_active = TRUE AND u.id <> v_actor
      AND can_view_user_schedule(u.id)
    ORDER BY u.full_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
