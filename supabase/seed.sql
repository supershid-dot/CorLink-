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
--
-- ─── Example: an organization's designations (job titles) ──
-- Purely descriptive picklist, managed by the organization's own admin —
-- optional and independent of the section/role assignments above.
-- INSERT INTO designations (org_id, name) VALUES
--   ('00000000-0000-0000-0000-000000000002', 'Legal Officer'),
--   ('00000000-0000-0000-0000-000000000002', 'Case Manager');
--
-- ─── Example: looping another section in on a request (internal-only) ──
-- Org-only collaboration, anchored to one external request — never
-- visible to the other organization in that conversation.
-- INSERT INTO internal_requests (parent_request_id, from_section_id, to_section_id, created_by, subject, body) VALUES
--   ('<REQUEST_UUID>', '00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000040',
--    '<STAFF_UUID>', 'FYI: case review', '<p>Please confirm the latest treatment notes.</p>');
--
-- ─── Example: Entry logging a public email, then routing it ──────
-- Entry staff log what arrived (org_id/entered_by only — no from_org_id/
-- to_org_id, since the sender isn't a CorLink organization at all), then
-- a supervisor/Entry staffer routes it to the responsible section.
-- INSERT INTO external_correspondence (org_id, source_channel, sender_category, sender_name, sender_contact, subject, body, entered_by, reference_number) VALUES
--   ('00000000-0000-0000-0000-000000000001', 'email', 'public', 'Aishath Ali', 'aishath@example.com',
--    'Request for visitation schedule', '<p>Could you share the current visitation hours for Maafushi Prison?</p>',
--    '<STAFF_UUID>', 'ENT-MCS-2026-0001');
-- UPDATE external_correspondence SET to_section_id = '00000000-0000-0000-0000-000000000030', status = 'routed'
--   WHERE reference_number = 'ENT-MCS-2026-0001';
