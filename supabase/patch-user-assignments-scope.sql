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
-- ============================================================

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
CREATE OR REPLACE FUNCTION has_role_in_section(p_section_id UUID, p_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments ua, sections s
    WHERE s.id = p_section_id
      AND ua.user_id = auth.uid() AND ua.role = p_role AND ua.is_active = TRUE
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION my_section_ids()
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION my_supervised_section_ids()
RETURNS SETOF UUID AS $$
  SELECT s.id
  FROM sections s
  WHERE EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
      AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
      AND (
        (ua.scope_type = 'section'    AND ua.scope_id = s.id) OR
        (ua.scope_type = 'department' AND ua.scope_id = s.department_id) OR
        (ua.scope_type = 'division'   AND ua.scope_id = s.division_id) OR
        (ua.scope_type = 'command'    AND ua.scope_id IN (
           SELECT d.command_id FROM departments d WHERE d.id = s.department_id
        ))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── Audit log: scope non-super-admins to their own organization ──
DROP POLICY IF EXISTS "audit_select" ON audit_logs;
CREATE POLICY "audit_select" ON audit_logs
  FOR SELECT USING (
    is_super_admin() OR
    (is_admin() AND EXISTS (
      SELECT 1 FROM users u WHERE u.id = audit_logs.user_id AND u.org_id = get_my_org_id()
    ))
  );
