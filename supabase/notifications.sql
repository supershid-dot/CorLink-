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
      -- deadline is a full TIMESTAMPTZ (carries a time of day), so compare
      -- against NOW() rather than CURRENT_DATE. A deadline that falls due
      -- mid-day is flagged 'overdue' by the next nightly run; the UI already
      -- computes overdue in real time (new Date(deadline) < now) regardless.
      AND deadline < NOW()
      AND status NOT IN ('draft', 'closed', 'responded', 'overdue', 'cancelled')
  LOOP
    UPDATE requests SET status = 'overdue' WHERE id = r.id;

    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'deadline_warning', 'request', r.id,
           'Request "' || r.subject || '" is overdue (deadline was '
             || to_char(r.deadline, 'YYYY-MM-DD HH24:MI') || ')'
    -- section_user_ids() is a SETOF UUID function — its result column
    -- is anonymous (named after the function itself), not "user_id".
    -- "AS uid" here aliases that column so SELECT uid below can see it;
    -- the previous "SELECT user_id AS uid FROM section_user_ids(...)"
    -- form referenced a column that doesn't exist, which raised a hard
    -- error on every run with at least one overdue request — rolling
    -- back the whole function call, including every status flip to
    -- 'overdue' already made earlier in this same loop. Caught here by
    -- actually exercising this function against real data rather than
    -- just reading it, since it had never been.
    FROM section_user_ids(
      COALESCE(r.to_section_id, r.from_section_id),
      ARRAY['mcs_admin', 'authority_admin', 'supervisor']
    ) AS uid;
  END LOOP;

  -- Entry (external_correspondence) has no 'overdue' status to flip to
  -- (its state machine is logged -> routed -> responded -> closed, no
  -- overlay status the way requests has) — this only notifies, once
  -- per case, deduped via NOT EXISTS against notifications instead of
  -- a status change. deadline is a DATE (not TIMESTAMPTZ, unlike
  -- requests.deadline), so the cutoff is CURRENT_DATE, not NOW() — an
  -- entry only counts as overdue once its whole deadline day has
  -- passed, matching the UI's own end-of-day overdue semantics.
  -- Unrouted entries (to_section_id IS NULL) are skipped: there's no
  -- single section to notify yet, and they're already surfaced via the
  -- dashboard's "Unrouted Entries" row regardless of deadline.
  FOR r IN
    SELECT id, to_section_id, subject, deadline
    FROM external_correspondence
    WHERE deadline IS NOT NULL
      AND deadline < CURRENT_DATE
      AND to_section_id IS NOT NULL
      AND status NOT IN ('responded', 'closed')
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.record_type = 'external_correspondence' AND n.record_id = external_correspondence.id
          AND n.type = 'deadline_warning'
      )
  LOOP
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'deadline_warning', 'external_correspondence', r.id,
           'Entry "' || r.subject || '" is overdue (deadline was ' || to_char(r.deadline, 'YYYY-MM-DD') || ')'
    FROM section_user_ids(
      r.to_section_id, ARRAY['mcs_admin', 'authority_admin', 'supervisor']
    ) AS uid;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Runs daily at 03:00 UTC. Re-running this file re-schedules it
-- (unschedule first) rather than erroring on a duplicate job name.
SELECT cron.unschedule('check-deadlines-daily')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'check-deadlines-daily');

SELECT cron.schedule('check-deadlines-daily', '0 3 * * *', $$SELECT check_deadlines();$$);
