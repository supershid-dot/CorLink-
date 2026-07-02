-- ============================================================
-- CorLink — Seed Data
-- Run AFTER schema.sql and rls.sql.
-- Sets up the MCS organization and initial structure.
-- ============================================================

-- ─── MCS Organization ────────────────────────────────────────
INSERT INTO organizations (id, name, type, code, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'Maldives Correctional Service',
  'mcs',
  'MCS',
  TRUE
);

-- ─── HRCM (Human Rights Commission) ─────────────────────────
INSERT INTO organizations (id, name, type, code, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  'Human Rights Commission of the Maldives',
  'authority',
  'HRCM',
  TRUE
);

-- ─── Example MCS Command ─────────────────────────────────────
INSERT INTO commands (id, org_id, name)
VALUES (
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000001',
  'Operations Command'
);

-- ─── Example MCS Department ──────────────────────────────────
INSERT INTO departments (id, command_id, name)
VALUES (
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000010',
  'Legal & Compliance Department'
);

-- ─── Example MCS Section ─────────────────────────────────────
INSERT INTO sections (id, org_id, department_id, name, code)
VALUES (
  '00000000-0000-0000-0000-000000000030',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  'Legal Affairs Section',
  'LGL'
);

-- ─── Example HRCM Division ───────────────────────────────────
INSERT INTO divisions (id, org_id, name)
VALUES (
  '00000000-0000-0000-0000-000000000040',
  '00000000-0000-0000-0000-000000000002',
  'Complaints & Monitoring Division'
);

-- ─── Example HRCM Section ────────────────────────────────────
INSERT INTO sections (id, org_id, division_id, name, code)
VALUES (
  '00000000-0000-0000-0000-000000000050',
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000040',
  'Legal Section',
  'LGL'
);

-- ─── Note on Super Admin User ─────────────────────────────────
-- The super admin user must be created via Supabase Auth dashboard first:
--   Email: SUPERADMIN_SERVICE_NUMBER@corlink.internal
--   Password: (strong, meets policy)
-- Then insert their profile here with the UUID returned by Supabase Auth.
-- Super admin is a system-wide flag (is_super_admin = TRUE) — it does NOT
-- need a user_assignments row, since super admins bypass section scoping.
--
-- INSERT INTO users (id, org_id, service_number, full_name, email, is_super_admin)
-- VALUES (
--   '<AUTH_UUID_FROM_SUPABASE>',
--   '00000000-0000-0000-0000-000000000001',
--   'MCS-001',
--   'System Administrator',
--   'admin@mcs.gov.mv',
--   TRUE
-- );
--
-- ─── Example: a staff member who is ALSO a supervisor in another section ──
-- INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary) VALUES
--   ('<STAFF_UUID>', 'section', '00000000-0000-0000-0000-000000000030', 'staff', TRUE),
--   ('<STAFF_UUID>', 'section', '00000000-0000-0000-0000-000000000050', 'supervisor', FALSE);
--
-- ─── Example: a department head, assigned once at department level ──
-- (covers every section under that department — no per-section rows needed)
-- INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary) VALUES
--   ('<HEAD_UUID>', 'department', '00000000-0000-0000-0000-000000000020', 'supervisor', TRUE);
--
-- ─── Example: an organization's own admin, assigned org-wide ──
-- (created by MCS/super admin right after the organization itself — this
-- is how an authority's first admin exists before it has any structure
-- of its own to be scoped to; they build that structure afterward)
-- INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary) VALUES
--   ('<AUTHORITY_ADMIN_UUID>', 'organization', '00000000-0000-0000-0000-000000000002', 'authority_admin', TRUE);
