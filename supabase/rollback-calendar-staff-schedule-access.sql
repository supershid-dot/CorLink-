-- Rollback for patch-calendar-staff-schedule-access.sql (137).
-- Drops the four new functions and the user_schedule_grants table.
--
-- Refuses unconditionally if any grant row exists — an admin's
-- deliberate "staff who is approved by the admin" access decisions
-- would otherwise be silently destroyed. Clear them first (or keep
-- this patch applied) if you are certain.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM user_schedule_grants LIMIT 1) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one schedule-access grant exists — an admin''s explicit "who can view whose schedule" decision would be destroyed. Clear user_schedule_grants first if you are certain, or keep this patch applied.';
  END IF;
END $$;

DROP FUNCTION IF EXISTS admin_set_schedule_grants(UUID, UUID[]);
DROP FUNCTION IF EXISTS fetch_user_calendar_events(UUID, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS viewable_calendar_staff();
DROP FUNCTION IF EXISTS can_view_user_schedule(UUID);
DROP TABLE IF EXISTS user_schedule_grants;

COMMIT;
