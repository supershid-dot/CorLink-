-- ============================================================
-- CorLink — Notifications & Deadline Tracking (Phase 5)
-- Run AFTER rls.sql.
--
-- Adds:
--  1. section_user_ids() / org_supervisor_user_ids() — helper RPCs the
--     client calls to find who to notify at a given workflow step
--     (see js/data/requests-api.js and prisoner-letters-api.js, which
--     call these before inserting notification rows).
--  2. check_deadlines() — flips overdue requests to status='overdue'
--     and notifies the people who can act on them, scheduled via
--     pg_cron. Requires the pg_cron extension, which on Supabase is
--     enabled per-project under Database → Extensions (search
--     "pg_cron") — it isn't on by default.
-- ============================================================

-- Supabase allows enabling pg_cron directly via SQL (it's on their
-- curated extension allowlist) — if this line errors with a
-- permissions message on your project, enable it instead via
-- Database → Extensions → search "pg_cron" in the dashboard, then
-- re-run just the CREATE POLICY/FUNCTION statements below.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ─── section_user_ids ───────────────────────────────────────────
-- Every user with an active assignment covering p_section_id (via the
-- same command/department/division/section expansion as
-- my_section_ids()), optionally filtered to specific roles.
CREATE OR REPLACE FUNCTION section_user_ids(p_section_id UUID, p_roles TEXT[] DEFAULT NULL)
RETURNS SETOF UUID AS $$
  SELECT DISTINCT ua.user_id
  FROM user_assignments ua
  WHERE ua.is_active = TRUE
    AND p_section_id IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
    AND (p_roles IS NULL OR ua.role = ANY(p_roles));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── org_supervisor_user_ids ────────────────────────────────────
-- Every supervisor/admin who's a member of p_org_id — used for
-- "notify the receiving org that mail has arrived" before it's been
-- routed to any specific section. Deliberately excludes super admins:
-- they administer the whole system, not any one org's day-to-day
-- workflow, so routine per-org notifications would just be noise.
CREATE OR REPLACE FUNCTION org_supervisor_user_ids(p_org_id UUID)
RETURNS SETOF UUID AS $$
  SELECT DISTINCT ua.user_id
  FROM user_assignments ua
  JOIN users u ON u.id = ua.user_id
  WHERE ua.is_active = TRUE
    AND u.org_id = p_org_id
    AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── check_deadlines ────────────────────────────────────────────
-- Flips requests past their deadline to status='overdue' and notifies
-- whoever can act on them (the receiving section if routed, otherwise
-- the sending section — both via section_user_ids). SECURITY DEFINER
-- so it can run from pg_cron with no authenticated user context;
-- everything it touches is scoped explicitly by section/org id rather
-- than relying on auth.uid()-based helpers like my_section_ids().
CREATE OR REPLACE FUNCTION check_deadlines()
RETURNS void AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id, from_section_id, to_section_id, subject, deadline
    FROM requests
    WHERE deadline IS NOT NULL
      AND deadline < CURRENT_DATE
      AND status NOT IN ('draft', 'closed', 'responded', 'overdue', 'cancelled')
  LOOP
    UPDATE requests SET status = 'overdue' WHERE id = r.id;

    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'deadline_warning', 'request', r.id,
           'Request "' || r.subject || '" is overdue (deadline was ' || r.deadline || ')'
    FROM (
      SELECT user_id AS uid FROM section_user_ids(
        COALESCE(r.to_section_id, r.from_section_id),
        ARRAY['mcs_admin', 'authority_admin', 'supervisor']
      )
    ) recipients;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Runs daily at 03:00 UTC. Re-running this file re-schedules it
-- (unschedule first) rather than erroring on a duplicate job name.
SELECT cron.unschedule('check-deadlines-daily')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'check-deadlines-daily');

SELECT cron.schedule('check-deadlines-daily', '0 3 * * *', $$SELECT check_deadlines();$$);
