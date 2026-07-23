-- ============================================================
-- CorLink — Calendar Frontend Route Activation
--
-- The 'calendar' module_key was already seeded in
-- patch-platform-module-foundation.sql with route = NULL ("no working
-- route yet"). The Calendar frontend now exists (js/views/calendar.js,
-- js/data/calendar-api.js), so this one-line, additive, idempotent
-- flip is the only remaining piece: without it, admin.js's Modules tab
-- keeps the org-enable toggle disabled for every organization,
-- regardless of how complete the frontend is. Mirrors
-- patch-rooms-route-activation.sql / patch-meetings-route-activation.sql
-- exactly.
--
-- Activates ONLY the 'calendar' module_key. Does not touch any other
-- module_key. No table, RLS, trigger, or function is created, altered,
-- or touched by this file — Calendar reads meetings/meeting_room_bookings/
-- meeting_room_blocks directly through their own existing, unchanged
-- RLS policies (docs/23 Phase C §3); this migration's only job is
-- making the route reachable.
--
-- Enabling 'calendar' for a specific organization remains a separate,
-- later, per-org admin action (Admin > Modules) — this patch does not
-- enable it for anyone, exactly matching the meetings/rooms precedent.
--
-- Safe to re-run.
-- ============================================================

BEGIN;

UPDATE platform_modules
  SET route = 'calendar'
  WHERE module_key = 'calendar' AND route IS DISTINCT FROM 'calendar';

COMMIT;
