-- ============================================================
-- CorLink — Patch: scope commands/departments INSERT policies
-- to the caller's own organization.
--
-- Run this INSTEAD of re-running the full rls.sql — it only
-- touches the two policies that changed, so your existing data
-- (organizations, sections, users, etc.) is untouched.
-- ============================================================

DROP POLICY IF EXISTS "commands_insert" ON commands;
CREATE POLICY "commands_insert" ON commands
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_role('mcs_admin') AND org_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "departments_insert" ON departments;
CREATE POLICY "departments_insert" ON departments
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_role('mcs_admin') AND EXISTS (
      SELECT 1 FROM commands c WHERE c.id = command_id AND c.org_id = get_my_org_id()
    ))
  );

DROP POLICY IF EXISTS "departments_update" ON departments;
CREATE POLICY "departments_update" ON departments
  FOR UPDATE USING (
    is_super_admin() OR
    (has_role('mcs_admin') AND EXISTS (
      SELECT 1 FROM commands c WHERE c.id = command_id AND c.org_id = get_my_org_id()
    ))
  );
