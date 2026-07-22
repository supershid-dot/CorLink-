-- ============================================================
-- CorLink — Meetings Frontend Route Activation
--
-- The 'meetings' module_key was seeded in patch-platform-module-
-- foundation.sql, and left with route = NULL by patch-meetings-
-- foundation.sql (docs/12-meetings-v1-decisions.md §19 step 3:
-- "platform_modules.meetings.route stays NULL until [the frontend]
-- ships"). The Meetings frontend now exists (docs/16-meetings-
-- frontend.md), so this one-line, additive, idempotent flip is the
-- only remaining piece: without it, admin.js's Modules tab keeps the
-- org-enable toggle disabled ("No route shipped yet — cannot be
-- enabled") for every organization, regardless of how complete the
-- frontend is. Mirrors patch-rooms-route-activation.sql exactly.
--
-- Activates ONLY the 'meetings' module_key. Does not touch 'rooms' or
-- any other module_key. No table, RLS, trigger, or function is
-- touched. Safe to re-run.
-- ============================================================

BEGIN;

UPDATE platform_modules
  SET route = 'meetings'
  WHERE module_key = 'meetings' AND route IS DISTINCT FROM 'meetings';

COMMIT;
