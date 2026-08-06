-- CAP-002 Phase 5.1 delegation/substitution foundation RLS suite
-- (12 scenarios). Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfdsr_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
CREATE TEMP TABLE wfdsr_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wfdsr_ids, wfdsr_results TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65030000-0000-0000-0000-000000000001','WF Delegation Sub RLS A','authority','WFDSR-A'),
 ('65030000-0000-0000-0000-000000000002','WF Delegation Sub RLS B','authority','WFDSR-B');
INSERT INTO auth.users(id,email) VALUES
 ('65030000-0001-0000-0000-000000000001','admin@wfdsr.local'),
 ('65030000-0001-0000-0000-000000000002','alice@wfdsr.local'),
 ('65030000-0001-0000-0000-000000000003','bob@wfdsr.local'),
 ('65030000-0001-0000-0000-000000000004','outsider@wfdsr.local'),
 ('65030000-0001-0000-0000-000000000005','otherorg@wfdsr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65030000-0001-0000-0000-000000000001','65030000-0000-0000-0000-000000000001','WFDSR-1','Admin','admin@wfdsr.local',true),
 ('65030000-0001-0000-0000-000000000002','65030000-0000-0000-0000-000000000001','WFDSR-2','Alice','alice@wfdsr.local',true),
 ('65030000-0001-0000-0000-000000000003','65030000-0000-0000-0000-000000000001','WFDSR-3','Bob','bob@wfdsr.local',true),
 ('65030000-0001-0000-0000-000000000004','65030000-0000-0000-0000-000000000001','WFDSR-4','Outsider','outsider@wfdsr.local',true),
 ('65030000-0001-0000-0000-000000000005','65030000-0000-0000-0000-000000000002','WFDSR-5','OtherOrg','otherorg@wfdsr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65030000-0001-0000-0000-000000000001','organization','65030000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65030000-0001-0000-0000-000000000002','organization','65030000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65030000-0001-0000-0000-000000000003','organization','65030000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65030000-0001-0000-0000-000000000004','organization','65030000-0000-0000-0000-000000000001','staff',true,true),
 ('65030000-0001-0000-0000-000000000005','organization','65030000-0000-0000-0000-000000000002','authority_admin',true,true);

\set ADMIN '{"sub":"65030000-0001-0000-0000-000000000001"}'
\set ALICE '{"sub":"65030000-0001-0000-0000-000000000002"}'
\set BOB '{"sub":"65030000-0001-0000-0000-000000000003"}'
\set OUTSIDER '{"sub":"65030000-0001-0000-0000-000000000004"}'
\set OTHERORG '{"sub":"65030000-0001-0000-0000-000000000005"}'

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65030000-0000-0000-0000-000000000001','65030000-0001-0000-0000-000000000002','65030000-0001-0000-0000-000000000003',
    '{"type":"organization_role","organization_id":"65030000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now(), now() + interval '5 days', 'coverage', gen_random_uuid());
  INSERT INTO wfdsr_ids VALUES ('d1', v_id);
END $$;

SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65030000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65030000-0001-0000-0000-000000000002"}'::jsonb,
    '65030000-0001-0000-0000-000000000003','planned_leave', now(), now() + interval '5 days', 'leave', gen_random_uuid());
  INSERT INTO wfdsr_ids VALUES ('s1', v_id);
END $$;

-- ── 1: delegator visibility ─────────────────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 1 THEN
    RAISE EXCEPTION 'expected the delegator to see their own delegation';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (1,'the delegator can see their own delegation record');

-- ── 2: delegate visibility ──────────────────────────────────────────
SELECT set_config('request.jwt.claims', :'BOB', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 1 THEN
    RAISE EXCEPTION 'expected the delegate to see the delegation naming them';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (2,'the delegate can see a delegation naming them');

-- ── 3: authorized administrator visibility ──────────────────────────
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 1 THEN
    RAISE EXCEPTION 'expected an authorized administrator to see the delegation';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (3,'an authorized administrator of the delegation''s organization can see it');

-- ── 4: unrelated same-organization staff denied ─────────────────────
SELECT set_config('request.jwt.claims', :'OUTSIDER', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 0 THEN
    RAISE EXCEPTION 'expected an unrelated same-organization staff member to see zero delegation rows';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (4,'a same-organization staff member who is neither delegator, delegate, nor administrator sees zero rows');

-- ── 5: cross-organization staff denied ──────────────────────────────
SELECT set_config('request.jwt.claims', :'OTHERORG', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 0 THEN
    RAISE EXCEPTION 'expected a cross-organization actor to see zero delegation rows';
  END IF;
  IF (SELECT count(*) FROM workflow_substitutions WHERE id = (SELECT id FROM wfdsr_ids WHERE name='s1')) <> 0 THEN
    RAISE EXCEPTION 'expected a cross-organization actor to see zero substitution rows';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (5,'a cross-organization actor sees zero delegation or substitution rows');

-- ── 6: substitution subject visibility where allowed ────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_substitutions WHERE id = (SELECT id FROM wfdsr_ids WHERE name='s1')) <> 1 THEN
    RAISE EXCEPTION 'expected the represented user (subject) to see the substitution naming them';
  END IF;
END $$;
SELECT set_config('request.jwt.claims', :'BOB', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_substitutions WHERE id = (SELECT id FROM wfdsr_ids WHERE name='s1')) <> 1 THEN
    RAISE EXCEPTION 'expected the substitute to see the substitution naming them';
  END IF;
END $$;
SELECT set_config('request.jwt.claims', :'OUTSIDER', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_substitutions WHERE id = (SELECT id FROM wfdsr_ids WHERE name='s1')) <> 0 THEN
    RAISE EXCEPTION 'expected an unrelated same-organization staff member to see zero substitution rows (no organization-wide history for ordinary staff)';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (6,'the represented user and the substitute can see the substitution naming them; an unrelated staff member cannot see organization-wide substitution history');

-- ── 7: evidence visibility follows parent record ────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfdsr_ids WHERE name='d1')) < 1 THEN
    RAISE EXCEPTION 'expected the delegator to see delegation evidence';
  END IF;
  IF (SELECT count(*) FROM workflow_substitution_events WHERE substitution_id = (SELECT id FROM wfdsr_ids WHERE name='s1')) < 1 THEN
    RAISE EXCEPTION 'expected the represented user to see substitution evidence';
  END IF;
END $$;
SELECT set_config('request.jwt.claims', :'OTHERORG', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfdsr_ids WHERE name='d1')) <> 0 THEN
    RAISE EXCEPTION 'expected a cross-organization actor to see zero delegation evidence rows';
  END IF;
  IF (SELECT count(*) FROM workflow_substitution_events WHERE substitution_id = (SELECT id FROM wfdsr_ids WHERE name='s1')) <> 0 THEN
    RAISE EXCEPTION 'expected a cross-organization actor to see zero substitution evidence rows';
  END IF;
END $$;
INSERT INTO wfdsr_results VALUES (7,'lifecycle evidence visibility follows the exact same predicate as its parent record, both allowing and denying identically');

-- ── 8: direct authenticated INSERT denied ───────────────────────────
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$ BEGIN
  BEGIN
    INSERT INTO workflow_delegations (organization_id, delegator_id, delegate_id, scope_type, scope_role_organization_id, scope_role,
      kind, activation_mode, starts_at, ends_at, status, created_by, create_idempotency_key)
    VALUES ('65030000-0000-0000-0000-000000000001','65030000-0001-0000-0000-000000000002','65030000-0001-0000-0000-000000000003',
      'organization_role','65030000-0000-0000-0000-000000000001','supervisor','temporary','manual', now(), now()+interval '1 day',
      'pending_acceptance','65030000-0001-0000-0000-000000000001', gen_random_uuid());
    RAISE EXCEPTION 'expected direct authenticated INSERT on workflow_delegations to be denied';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct authenticated INSERT on workflow_delegations to be denied' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfdsr_results VALUES (8,'a direct authenticated INSERT into workflow_delegations is denied (no grant beyond SELECT)');

-- ── 9: direct authenticated UPDATE denied ───────────────────────────
DO $$ BEGIN
  BEGIN
    UPDATE workflow_delegations SET reason = 'tampered' WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1');
    RAISE EXCEPTION 'expected direct authenticated UPDATE on workflow_delegations to be denied';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct authenticated UPDATE on workflow_delegations to be denied' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfdsr_results VALUES (9,'a direct authenticated UPDATE on workflow_delegations is denied (no grant beyond SELECT)');

-- ── 10: direct authenticated DELETE denied ──────────────────────────
DO $$ BEGIN
  BEGIN
    DELETE FROM workflow_delegations WHERE id = (SELECT id FROM wfdsr_ids WHERE name='d1');
    RAISE EXCEPTION 'expected direct authenticated DELETE on workflow_delegations to be denied';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct authenticated DELETE on workflow_delegations to be denied' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfdsr_results VALUES (10,'a direct authenticated DELETE on workflow_delegations is denied (no grant beyond SELECT)');

-- ── 11: anonymous access denied ─────────────────────────────────────
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM count(*) FROM workflow_delegations;
    RAISE EXCEPTION 'expected anon to be denied SELECT on workflow_delegations';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected anon to be denied SELECT on workflow_delegations' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_workflow_delegation('65030000-0000-0000-0000-000000000001','65030000-0001-0000-0000-000000000002',
      '65030000-0001-0000-0000-000000000003','{"type":"organization_role","organization_id":"65030000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now()+interval '1 day', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected anon to be denied EXECUTE on create_workflow_delegation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected anon to be denied EXECUTE on create_workflow_delegation' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
INSERT INTO wfdsr_results VALUES (11,'the anon role is denied both table SELECT and every mutating RPC');

-- ── 12: private helpers not executable ──────────────────────────────
DO $$
DECLARE v_leak TEXT := '';
BEGIN
  IF has_function_privilege('anon', 'can_manage_workflow_delegation_scope(uuid)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'can_manage_workflow_delegation_scope(uuid)'::regprocedure, 'EXECUTE')
  THEN v_leak := v_leak || 'can_manage_workflow_delegation_scope '; END IF;
  IF has_function_privilege('anon', 'workflow_reject_terminal_delegation_mutation()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'workflow_reject_terminal_delegation_mutation()'::regprocedure, 'EXECUTE')
  THEN v_leak := v_leak || 'workflow_reject_terminal_delegation_mutation '; END IF;
  IF has_function_privilege('anon', 'workflow_reject_delegation_event_mutation()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'workflow_reject_delegation_event_mutation()'::regprocedure, 'EXECUTE')
  THEN v_leak := v_leak || 'workflow_reject_delegation_event_mutation '; END IF;
  IF has_function_privilege('anon', 'workflow_reject_terminal_substitution_mutation()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'workflow_reject_terminal_substitution_mutation()'::regprocedure, 'EXECUTE')
  THEN v_leak := v_leak || 'workflow_reject_terminal_substitution_mutation '; END IF;
  -- The two RLS-referenced visibility helpers are deliberately
  -- authenticated-executable (RLS depends on it) but must still deny
  -- anon.
  IF has_function_privilege('anon', 'workflow_delegation_visible_to_caller(uuid,uuid,uuid)'::regprocedure, 'EXECUTE') THEN
    v_leak := v_leak || 'workflow_delegation_visible_to_caller-anon-leak ';
  END IF;
  IF has_function_privilege('anon', 'workflow_substitution_visible_to_caller(text,uuid,uuid,uuid)'::regprocedure, 'EXECUTE') THEN
    v_leak := v_leak || 'workflow_substitution_visible_to_caller-anon-leak ';
  END IF;
  IF v_leak <> '' THEN RAISE EXCEPTION 'private helper execute-leak: %', v_leak; END IF;
END $$;
INSERT INTO wfdsr_results VALUES (12,'fully private helpers are ungranted to both anon and authenticated; the two RLS-referenced visibility helpers are authenticated-only, never anon');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfdsr_results;
  IF v_count <> 12 THEN
    RAISE EXCEPTION 'Workflow delegation/substitution foundation RLS tests FAILED: expected 12, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution foundation RLS tests PASSED: %/12', v_count;
END $$;

ROLLBACK;
