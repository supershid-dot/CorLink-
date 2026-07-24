-- ============================================================
-- CorLink — Rooms and Booking Frontend Route Activation
--
-- The 'rooms' module_key was seeded in patch-platform-module-
-- foundation.sql with route = NULL — deliberately unshipped and
-- unreachable until a real frontend existed (docs/09-rooms-booking-
-- v1-decisions.md's own conformance check). The Rooms and Booking
-- frontend now exists (docs/15-rooms-booking-frontend.md), so this
-- one-line, additive, idempotent flip is the only remaining piece:
-- without it, admin.js's Modules tab keeps the org-enable toggle
-- disabled ("No route shipped yet — cannot be enabled") for every
-- organization, regardless of how complete the frontend is.
--
-- No table, RLS, trigger, or function is touched. Safe to re-run.
-- ============================================================

BEGIN;

UPDATE platform_modules
  SET route = 'rooms'
  WHERE module_key = 'rooms' AND route IS DISTINCT FROM 'rooms';

COMMIT;
