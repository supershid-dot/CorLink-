-- ============================================================
-- CorLink — Patch: add designations (staff job titles/positions)
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql.
--
-- Why: staff need a descriptive job title/position separate from
-- their section-role assignment (user_assignments.role is the
-- authorization-relevant role — staff/supervisor/etc — not a title).
-- Designations are a per-organization picklist managed by that
-- organization's own admin (mirrors how they manage their own
-- command/department/division/section structure) — MCS does not set
-- designations for other organizations. Purely descriptive: it has
-- no bearing on RLS/role logic.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS designations (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, name)
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS designation_id UUID REFERENCES designations(id);

ALTER TABLE designations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "designations_select" ON designations;
CREATE POLICY "designations_select" ON designations
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "designations_insert" ON designations;
CREATE POLICY "designations_insert" ON designations
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "designations_update" ON designations;
CREATE POLICY "designations_update" ON designations
  FOR UPDATE USING (
    is_super_admin() OR
    (is_admin() AND org_id = get_my_org_id())
  );

COMMIT;
