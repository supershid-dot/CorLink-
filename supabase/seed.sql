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
-- Then insert their profile here with the UUID returned by Supabase Auth:
--
-- INSERT INTO users (id, org_id, section_id, service_number, full_name, email, role)
-- VALUES (
--   '<AUTH_UUID_FROM_SUPABASE>',
--   '00000000-0000-0000-0000-000000000001',
--   '00000000-0000-0000-0000-000000000030',
--   'MCS-001',
--   'System Administrator',
--   'admin@mcs.gov.mv',
--   'super_admin'
-- );
