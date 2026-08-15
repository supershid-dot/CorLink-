-- ============================================================
-- NON-PRODUCTION. Local disposable-Postgres test harness only.
-- Applied ONLY by apply-canonical-schema.sh --local-test-harness, in
-- place of the real notifications.sql, when pg_cron is unavailable
-- (common in ephemeral local containers; always available on a real
-- Supabase project — see supabase/auth-setup.md §6).
--
-- Contains ONLY the two functions from notifications.sql that later
-- CAP-003 patches genuinely reuse (section_user_ids(),
-- org_supervisor_user_ids()) — copied verbatim from the real file.
-- Deliberately omits check_deadlines() and its cron.schedule() call
-- (the pg_cron-dependent parts), and every other notifications.sql
-- RPC not reused by any later patch. This means a --local-test-
-- harness environment does NOT get the daily overdue-request check —
-- expected and acceptable for structural/regression testing, NOT
-- acceptable for a real deployment, which must run the real
-- notifications.sql instead.
-- ============================================================

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
