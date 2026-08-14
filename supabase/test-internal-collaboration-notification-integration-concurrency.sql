-- CAP-003 Phase 1.8B concurrency suite -- FIXTURE SETUP ONLY.
-- Disposable local PostgreSQL only. The actual concurrent execution
-- (genuine OS-level parallel sessions) is driven by the companion
-- shell script run-internal-collaboration-concurrency.sh, which issues
-- real parallel `psql` processes against the fixtures this file
-- creates -- more robust than dblink's async result-fetch protocol for
-- exercising genuine multi-session row-lock contention. Fixtures use
-- the '98200000-' UUID prefix convention.
\set ON_ERROR_STOP on

INSERT INTO organizations (id, name, type, code) VALUES ('98200000-0000-0000-0000-000000000001', 'IC98C Org', 'mcs', 'IC98C');
INSERT INTO commands (id, org_id, name) VALUES ('98200000-0001-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', 'Cmd');
INSERT INTO departments (id, command_id, name) VALUES ('98200000-0002-0000-0000-000000000001', '98200000-0001-0000-0000-000000000001', 'Dept');
INSERT INTO sections (id, department_id, org_id, name, code) VALUES
  ('98200000-0003-0000-0000-000000000001', '98200000-0002-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', 'Sec A', 'ICA'),
  ('98200000-0003-0000-0000-000000000002', '98200000-0002-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', 'Sec B', 'ICB'),
  ('98200000-0003-0000-0000-000000000003', '98200000-0002-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', 'Sec C', 'ICC');
INSERT INTO auth.users (id, email) VALUES
  ('98200000-0004-0000-0000-000000000001', 'creator@ic98c.local'),
  ('98200000-0004-0000-0000-000000000002', 'sup@ic98c.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
  ('98200000-0004-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', 'IC98-1', 'Creator', 'creator@ic98c.local', TRUE),
  ('98200000-0004-0000-0000-000000000002', '98200000-0000-0000-0000-000000000001', 'IC98-2', 'Org Supervisor', 'sup@ic98c.local', TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
  ('98200000-0004-0000-0000-000000000001', 'section', '98200000-0003-0000-0000-000000000001', 'staff', TRUE),
  ('98200000-0004-0000-0000-000000000002', 'organization', '98200000-0000-0000-0000-000000000001', 'supervisor', TRUE);
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, status, created_by, reference_number)
  VALUES ('98200000-0005-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', '98200000-0000-0000-0000-000000000001', '98200000-0003-0000-0000-000000000001', 'Parent', 'body', 'sent', '98200000-0004-0000-0000-000000000001', 'REQ-IC98C-1');

DO $$
DECLARE v_ir internal_requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"98200000-0004-0000-0000-000000000001"}', true);
  SELECT * INTO v_ir FROM create_internal_request(
    '98200000-0003-0000-0000-000000000001', '98200000-0003-0000-0000-000000000002',
    'IC98C thread', 'body', '98200000-0005-0000-0000-000000000001', NULL, 'en', 'en', NULL
  );
  RESET ROLE;
  RAISE NOTICE 'IC98C_IR1=%', v_ir.id;
END $$;
