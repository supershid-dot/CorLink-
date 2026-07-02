-- ============================================================
-- CorLink — Patch: add 'organization' as a user_assignments scope
-- level, alongside command/department/division/section.
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql.
--
-- Why: MCS (the super admin) creates an organization, then that
-- organization's own admin is supposed to build out its structure —
-- not MCS. But mcs_admin/authority_admin assignments previously had
-- to be scoped to an existing command/department/division/section,
-- which didn't exist yet for a brand-new organization. That made it
-- impossible to create an organization's first admin at all — a
-- chicken-and-egg bug. 'organization' scope lets an admin assignment
-- exist independent of any structure, matching how these roles are
-- inherently org-wide anyway (is_admin() already treats them that way
-- regardless of which scope they happen to be attached to).
-- ============================================================

BEGIN;

ALTER TABLE user_assignments DROP CONSTRAINT IF EXISTS user_assignments_scope_type_check;
ALTER TABLE user_assignments ADD CONSTRAINT user_assignments_scope_type_check
  CHECK (scope_type IN ('organization', 'command', 'department', 'division', 'section'));

CREATE OR REPLACE FUNCTION scope_org_id(p_scope_type TEXT, p_scope_id UUID)
RETURNS UUID AS $$
  SELECT CASE p_scope_type
    WHEN 'organization' THEN (SELECT id FROM organizations WHERE id = p_scope_id AND is_active = TRUE)
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
      )) OR
      (p_scope_type = 'organization' AND s.org_id = p_scope_id
         AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_scope_id AND o.is_active = TRUE))
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMIT;
