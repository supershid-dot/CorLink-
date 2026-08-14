-- CAP-003 Phase 1.9B concurrency suite -- FIXTURE SETUP ONLY.
-- Disposable local PostgreSQL only. The actual concurrent execution
-- (genuine OS-level parallel sessions) is driven by the companion
-- shell script run-prisoner-letters-notification-concurrency.sh, which
-- issues real parallel `psql` processes against the fixtures this file
-- creates -- more robust than dblink's async result-fetch protocol for
-- exercising genuine multi-session row-lock contention (matching the
-- precedent already established for CAP-003 Phase 1.8B's own
-- concurrency suite). Fixtures use the '99200000-' UUID prefix
-- convention.
\set ON_ERROR_STOP on

INSERT INTO organizations (id, name, type, code) VALUES
  ('99200000-0000-0000-0000-000000000001', 'PL99C Prison Org', 'mcs', 'PL99CP'),
  ('99200000-0000-0000-0000-000000000002', 'PL99C Authority Org', 'authority', 'PL99CQ');
INSERT INTO commands (id, org_id, name) VALUES
  ('99200000-0001-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001', 'Cmd P'),
  ('99200000-0001-0000-0000-000000000002', '99200000-0000-0000-0000-000000000002', 'Cmd Q');
INSERT INTO departments (id, command_id, name) VALUES
  ('99200000-0002-0000-0000-000000000001', '99200000-0001-0000-0000-000000000001', 'Dept P'),
  ('99200000-0002-0000-0000-000000000002', '99200000-0001-0000-0000-000000000002', 'Dept Q');
INSERT INTO sections (id, department_id, org_id, name, code) VALUES
  ('99200000-0003-0000-0000-000000000001', '99200000-0002-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001', 'Sec P', 'PL99SP'),
  ('99200000-0003-0000-0000-000000000002', '99200000-0002-0000-0000-000000000002', '99200000-0000-0000-0000-000000000002', 'Sec Q', 'PL99SQ');
INSERT INTO auth.users (id, email) VALUES
  ('99200000-0004-0000-0000-000000000001', 'mcs@pl99c.local'),
  ('99200000-0004-0000-0000-000000000002', 'authsup1@pl99c.local'),
  ('99200000-0004-0000-0000-000000000003', 'authsup2@pl99c.local'),
  ('99200000-0004-0000-0000-000000000004', 'assignee1@pl99c.local'),
  ('99200000-0004-0000-0000-000000000005', 'assignee2@pl99c.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active, is_prisoner_letters_staff) VALUES
  ('99200000-0004-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001', 'PL99C-1', 'MCS Staff', 'mcs@pl99c.local', TRUE, TRUE),
  ('99200000-0004-0000-0000-000000000002', '99200000-0000-0000-0000-000000000002', 'PL99C-2', 'Authority Super 1', 'authsup1@pl99c.local', TRUE, FALSE),
  ('99200000-0004-0000-0000-000000000003', '99200000-0000-0000-0000-000000000002', 'PL99C-3', 'Authority Super 2', 'authsup2@pl99c.local', TRUE, FALSE),
  ('99200000-0004-0000-0000-000000000004', '99200000-0000-0000-0000-000000000002', 'PL99C-4', 'Assignee 1', 'assignee1@pl99c.local', TRUE, TRUE),
  ('99200000-0004-0000-0000-000000000005', '99200000-0000-0000-0000-000000000002', 'PL99C-5', 'Assignee 2', 'assignee2@pl99c.local', TRUE, TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
  ('99200000-0004-0000-0000-000000000001', 'section', '99200000-0003-0000-0000-000000000001', 'staff', TRUE),
  ('99200000-0004-0000-0000-000000000002', 'organization', '99200000-0000-0000-0000-000000000002', 'supervisor', TRUE),
  ('99200000-0004-0000-0000-000000000003', 'organization', '99200000-0000-0000-0000-000000000002', 'supervisor', TRUE),
  ('99200000-0004-0000-0000-000000000004', 'section', '99200000-0003-0000-0000-000000000002', 'staff', TRUE),
  ('99200000-0004-0000-0000-000000000005', 'section', '99200000-0003-0000-0000-000000000002', 'staff', TRUE);
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('99200000-0005-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001', 'FILE-C99-1', 'PL99C-INMATE-1', 'PL99C Test Inmate', 'Test Address', 'Maafushi Prison');

DO $$
DECLARE v_pl prisoner_letters; v_pl2 prisoner_letters;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"99200000-0004-0000-0000-000000000001"}', true);
  SELECT * INTO v_pl FROM create_prisoner_letter(
    '99200000-0005-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001',
    '99200000-0000-0000-0000-000000000002', 'PL99C body 1'
  );
  SELECT * INTO v_pl2 FROM create_prisoner_letter(
    '99200000-0005-0000-0000-000000000001', '99200000-0000-0000-0000-000000000001',
    '99200000-0000-0000-0000-000000000002', 'PL99C body 2'
  );
  RESET ROLE;
  RAISE NOTICE 'PL99C_LETTER1=%', v_pl.id;
  RAISE NOTICE 'PL99C_LETTER2=%', v_pl2.id;
END $$;
