-- ============================================================
-- CorLink — Patch: generalize user_assignments from section-only
-- scoping to command/department/division/section scoping, so a
-- command or department head (MCS) / division head (Authority) can
-- be assigned once instead of once per section underneath them.
-- Also scopes the audit log to the admin's own organization.
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql — it
-- only touches user_assignments, its dependent helper functions,
-- and the audit_logs SELECT policy. Existing section-scoped
-- assignments are preserved (migrated to scope_type = 'section').
--
-- Wrapped in a transaction: if anything fails partway (e.g. the
-- UNIQUE constraint collides with pre-existing duplicate rows once
-- scope_type is added), the whole patch rolls back instead of
-- leaving user_assignments half-migrated.
-- ============================================================

BEGIN;

ALTER TABLE user_assignments ADD COLUMN scope_type TEXT;
ALTER TABLE user_assignments ADD COLUMN scope_id UUID;

UPDATE user_assignments SET scope_type = 'section', scope_id = section_id;

ALTER TABLE user_assignments ALTER COLUMN scope_type SET NOT NULL;
ALTER TABLE user_assignments ALTER COLUMN scope_id SET NOT NULL;
ALTER TABLE user_assignments ADD CONSTRAINT user_assignments_scope_type_check
  CHECK (scope_type IN ('command', 'department', 'division', 'section'));

DROP INDEX IF EXISTS idx_user_assignments_section;
ALTER TABLE user_assignments DROP CONSTRAINT IF EXISTS user_assignments_user_id_section_id_role_key;
ALTER TABLE user_assignments DROP COLUMN section_id;

ALTER TABLE user_assignments ADD CONSTRAINT user_assignments_user_id_scope_type_scope_id_role_key
  UNIQUE (user_id, scope_type, scope_id, role);
CREATE INDEX idx_user_assignments_scope ON user_assignments(scope_type, scope_id);

-- ─── Helper functions: expand scope to descendant sections ────
-- (single shared scope_section_ids()/scope_org_id() used by all three
-- RLS helpers below, instead of repeating the expansion logic —
-- and both respect is_active, so deactivating the assigned command/
-- department/division actually revokes access.)
CREATE OR REPLACE FUNCTION scope_org_id(p_scope_type TEXT, p_scope_id UUID)
RETURNS UUID AS $$
  SELECT CASE p_scope_type
    WHEN 'command'    THEN (SELECT org_id FROM commands WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'department' THEN (
      SELECT c.org_id FROM departments d JOIN commands c ON c.id = d.command_id
      WHERE d.id = p_scope_id AND d.is_active = TRUE AND c.is_active = TRUE
    )
    WHEN 'division'   THEN (SELECT org_id FROM divisions WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'section'    THEN (SELECT org_id FROM sections  WHERE id = p_scope_id AND is_active = TRUE)
    ELSE NULL
  END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION scope_section_ids(p_scope_type TEXT, p_scope_id UUID)
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE s.is_active = TRUE
    AND (
      (p_scope_type = 'section'    AND s.id = p_scope_id) OR
      (p_scope_type = 'department' AND s.department_id = p_scope_id
         AND EXISTS (SELECT 1 FROM departments d WHERE d.id = p_scope_id AND d.is_active = TRUE)) OR
      (p_scope_type = 'division'   AND s.division_id = p_scope_id
         AND EXISTS (SELECT 1 FROM divisions dv WHERE dv.id = p_scope_id AND dv.is_active = TRUE)) OR
      (p_scope_type = 'command'    AND EXISTS (
         SELECT 1 FROM departments d
         WHERE d.id = s.department_id AND d.command_id = p_scope_id AND d.is_active = TRUE
           AND EXISTS (SELECT 1 FROM commands c WHERE c.id = p_scope_id AND c.is_active = TRUE)
      ))
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION has_role_in_section(p_section_id UUID, p_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.role = p_role AND ua.is_active = TRUE
      AND p_section_id IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION my_section_ids()
RETURNS SETOF UUID AS $$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION my_supervised_section_ids()
RETURNS SETOF UUID AS $$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
    AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── Assignments: require scope to belong to the caller's own org ──
-- scope_id has no FK, so without this an org admin could insert an
-- assignment scoped to a DIFFERENT org's command/department/division/
-- section. Only added to INSERT (not UPDATE) — the app only ever
-- updates is_active/is_primary on existing rows, and an UPDATE check
-- here would block deactivating an assignment whose scope was itself
-- deactivated after the fact.
DROP POLICY IF EXISTS "assignments_insert" ON user_assignments;
CREATE POLICY "assignments_insert" ON user_assignments
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.id = user_assignments.user_id AND u.org_id = get_my_org_id()
    ) AND scope_org_id(scope_type, scope_id) = get_my_org_id())
  );

-- ─── Audit log: scope non-super-admins to their own organization ──
DROP POLICY IF EXISTS "audit_select" ON audit_logs;
CREATE POLICY "audit_select" ON audit_logs
  FOR SELECT USING (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u WHERE u.id = audit_logs.user_id AND u.org_id = get_my_org_id()
    ))
  );

COMMIT;
