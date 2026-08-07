-- CAP-003 Phase 1.0A -- legacy notification INSERT-RLS correction
-- rollback. Restores the exact pre-correction `notif_insert` policy
-- (byte-identical to its original definition in supabase/rls.sql) and
-- removes create_legacy_notification() entirely.
--
-- This intentionally restores the insecure pre-correction state -- it
-- exists for exact-rollback verification (policy/grant equality, clean
-- reapplication) during this milestone's own testing, not as an
-- operational recommendation to ever actually run it against a real
-- environment. No CASCADE is used.
--
-- Note: js/data/notifications-api.js's notify() was updated in the
-- same commit as this correction to call create_legacy_notification()
-- instead of a raw table insert. Running this SQL rollback alone,
-- without also reverting that JS change (a plain git revert of the
-- same commit), would leave the frontend calling an RPC that no longer
-- exists. This SQL artifact governs only the database objects it
-- created, exactly as every other CAP-002/CAP-003 rollback in this
-- repository does.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS create_legacy_notification(UUID[],TEXT,TEXT,UUID,TEXT);

CREATE POLICY "notif_insert" ON notifications
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

COMMIT;
