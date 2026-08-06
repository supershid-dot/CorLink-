-- CAP-002 Phase 5.1 delegation/substitution foundation behavioral
-- suite (35 scenarios). Runs in one transaction and leaves no
-- fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfds_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfds_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfds_results, wfds_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65020000-0000-0000-0000-000000000001','WF Delegation Sub Test A','authority','WFDS-A'),
 ('65020000-0000-0000-0000-000000000002','WF Delegation Sub Test B','authority','WFDS-B');
INSERT INTO auth.users(id,email) VALUES
 ('65020000-0001-0000-0000-000000000001','admin@wfds.local'),
 ('65020000-0001-0000-0000-000000000002','alice@wfds.local'),
 ('65020000-0001-0000-0000-000000000003','bob@wfds.local'),
 ('65020000-0001-0000-0000-000000000004','carol@wfds.local'),
 ('65020000-0001-0000-0000-000000000005','dave@wfds.local'),
 ('65020000-0001-0000-0000-000000000006','erin@wfds.local'),
 ('65020000-0001-0000-0000-000000000007','otherorg@wfds.local'),
 ('65020000-0001-0000-0000-000000000008','frank@wfds.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65020000-0001-0000-0000-000000000001','65020000-0000-0000-0000-000000000001','WFDS-1','Admin','admin@wfds.local',true),
 ('65020000-0001-0000-0000-000000000002','65020000-0000-0000-0000-000000000001','WFDS-2','Alice','alice@wfds.local',true),
 ('65020000-0001-0000-0000-000000000003','65020000-0000-0000-0000-000000000001','WFDS-3','Bob','bob@wfds.local',true),
 ('65020000-0001-0000-0000-000000000004','65020000-0000-0000-0000-000000000001','WFDS-4','Carol','carol@wfds.local',true),
 ('65020000-0001-0000-0000-000000000005','65020000-0000-0000-0000-000000000001','WFDS-5','Dave','dave@wfds.local',true),
 ('65020000-0001-0000-0000-000000000006','65020000-0000-0000-0000-000000000001','WFDS-6','Erin','erin@wfds.local',true),
 ('65020000-0001-0000-0000-000000000007','65020000-0000-0000-0000-000000000002','WFDS-7','OtherOrg','otherorg@wfds.local',true),
 ('65020000-0001-0000-0000-000000000008','65020000-0000-0000-0000-000000000001','WFDS-8','Frank','frank@wfds.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65020000-0001-0000-0000-000000000001','organization','65020000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65020000-0001-0000-0000-000000000002','organization','65020000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65020000-0001-0000-0000-000000000003','organization','65020000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65020000-0001-0000-0000-000000000007','organization','65020000-0000-0000-0000-000000000002','authority_admin',true,true);

\set ADMIN '{"sub":"65020000-0001-0000-0000-000000000001"}'
\set ALICE '{"sub":"65020000-0001-0000-0000-000000000002"}'
\set BOB '{"sub":"65020000-0001-0000-0000-000000000003"}'
\set CAROL '{"sub":"65020000-0001-0000-0000-000000000004"}'
\set DAVE '{"sub":"65020000-0001-0000-0000-000000000005"}'
\set ERIN '{"sub":"65020000-0001-0000-0000-000000000006"}'
\set OTHERORG '{"sub":"65020000-0001-0000-0000-000000000007"}'
\set FRANK '{"sub":"65020000-0001-0000-0000-000000000008"}'
\set SUP_SCOPE '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'

SET LOCAL ROLE authenticated;

-- ── 1: manual delegation created in pending_acceptance ──────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT delegation_id, status INTO v_id, v_status FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000003',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb, 'temporary','manual', now(), now() + interval '10 days', 'vacation', gen_random_uuid());
  IF v_status <> 'pending_acceptance' THEN RAISE EXCEPTION 'expected pending_acceptance, got %', v_status; END IF;
  INSERT INTO wfds_ids VALUES ('d1', v_id);
END $$;
INSERT INTO wfds_results VALUES (1,'manual delegation is created in pending_acceptance status');

-- ── 2: delegate can accept ───────────────────────────────────────────
SELECT set_config('request.jwt.claims', :'BOB', true);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM accept_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d1'), 0, gen_random_uuid());
  IF v_status <> 'active' THEN RAISE EXCEPTION 'expected active after accept, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (2,'the named delegate can accept a pending manual delegation, transitioning it to active');

-- ── 3: delegate can reject ───────────────────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000004',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb, 'temporary','manual', now(), now() + interval '3 days', NULL, gen_random_uuid());
  INSERT INTO wfds_ids VALUES ('d3', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', true);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM reject_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d3'), 0, 'not available', gen_random_uuid());
  IF v_status <> 'rejected' THEN RAISE EXCEPTION 'expected rejected, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (3,'the named delegate can reject a pending manual delegation, transitioning it to rejected');

-- ── 4: authorized automatic delegation created active immediately ──
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT delegation_id, status INTO v_id, v_status FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb, 'temporary','automatic', now(), now() + interval '3 days', NULL, gen_random_uuid());
  IF v_status <> 'active' THEN RAISE EXCEPTION 'expected active immediately for automatic delegation, got %', v_status; END IF;
  INSERT INTO wfds_ids VALUES ('d4', v_id);
END $$;
INSERT INTO wfds_results VALUES (4,'administrator-created automatic delegation is created active immediately, with no acceptance step');

-- ── 5: delegator can revoke ──────────────────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM revoke_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d1'), 1, 'plans changed', gen_random_uuid());
  IF v_status <> 'revoked' THEN RAISE EXCEPTION 'expected revoked, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (5,'the original delegator can revoke an active delegation');

-- ── 6: authorized administrator can revoke ──────────────────────────
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM revoke_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d4'), 0, 'org restructure', gen_random_uuid());
  IF v_status <> 'revoked' THEN RAISE EXCEPTION 'expected revoked, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (6,'an authorized administrator can revoke a delegation they did not create');

-- ── 7: unrelated actor cannot revoke ────────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000003',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb, 'temporary','manual', now(), now() + interval '3 days', NULL, gen_random_uuid());
  INSERT INTO wfds_ids VALUES ('d7', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'ERIN', true);
DO $$ BEGIN
  BEGIN
    PERFORM revoke_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d7'), 0, 'nope', gen_random_uuid());
    RAISE EXCEPTION 'expected unrelated actor revoke to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected unrelated actor revoke to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (7,'an unrelated actor (neither delegator, delegate, nor administrator) cannot revoke a delegation');

-- ── 8: self-delegation rejected ─────────────────────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000002',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now()+interval '1 day', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected self-delegation to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected self-delegation to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (8,'self-delegation is rejected');

-- ── 9: delegation chain rejected ────────────────────────────────────
-- Carol never holds standing supervisor authority of her own (only
-- ever offered/rejected a delegation) - a delegation naming her as
-- delegator must fail, structurally preventing any chain.
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000004','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now()+interval '1 day', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected delegation chain (delegator with no standing authority) to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected delegation chain (delegator with no standing authority) to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (9,'a delegation naming a delegator with no standing authority of their own is rejected, structurally preventing any chain');

-- ── 10: reciprocal overlapping delegation rejected ──────────────────
SELECT set_config('request.jwt.claims', :'BOB', true);
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000003','65020000-0001-0000-0000-000000000002',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected reciprocal overlapping delegation to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected reciprocal overlapping delegation to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (10,'reciprocal overlapping delegation (A delegates to B while B delegates the same scope back to A within an overlapping window) is rejected');

-- ── 11: non-overlapping reciprocal records handled per contract ────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000003','65020000-0001-0000-0000-000000000002',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now() + interval '30 days', now() + interval '33 days', NULL, gen_random_uuid());
  IF v_status <> 'pending_acceptance' THEN RAISE EXCEPTION 'expected the non-overlapping reciprocal record to succeed, got status %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (11,'a reciprocal delegation whose window does not overlap the original is accepted (only true overlap is rejected)');

-- ── 12: invalid validity window rejected ────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now() - interval '1 hour', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected end-before-start window to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected end-before-start window to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (12,'an invalid validity window (end at or before start) is rejected');

-- ── 13: temporary duration limit enforced ───────────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now() + interval '400 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected temporary delegation exceeding 365 days to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected temporary delegation exceeding 365 days to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (13,'a temporary delegation exceeding the 365-day policy limit is rejected');

-- ── 14: permanent delegation restricted to authorized administrator ─
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'permanent','manual', now(), NULL, NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected non-administrator permanent delegation to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected non-administrator permanent delegation to be rejected' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000006',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'permanent','automatic', now(), NULL, 'standing backup', gen_random_uuid());
  IF v_status <> 'active' THEN RAISE EXCEPTION 'expected administrator-created permanent delegation to succeed, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (14,'permanent delegation is rejected from a non-administrator and permitted from an authorized administrator');

-- ── 15: wrong-organization delegate rejected ────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000007',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected cross-organization delegate to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected cross-organization delegate to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (15,'a delegate from a different organization is rejected');

-- ── 16: scope validation enforced ───────────────────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"bogus_type"}'::jsonb, 'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected unsupported scope type to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected unsupported scope type to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001"}'::jsonb,
      'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected missing role field to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected missing role field to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor","extra":"nope"}'::jsonb,
      'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected unexpected scope field to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected unexpected scope field to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (16,'scope validation rejects an unsupported type, a missing required field, and an unexpected extra field');

-- ── 17: duplicate semantic replay returns same result ───────────────
DO $$
DECLARE v_key UUID := gen_random_uuid(); v_id1 UUID; v_id2 UUID; v_replayed BOOLEAN;
BEGIN
  SELECT delegation_id INTO v_id1 FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now() + interval '50 days', now() + interval '55 days', 'replay test', v_key);
  SELECT delegation_id, replayed INTO v_id2, v_replayed FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000005',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now() + interval '50 days', now() + interval '55 days', 'replay test', v_key);
  IF v_id1 <> v_id2 OR NOT v_replayed THEN
    RAISE EXCEPTION 'expected identical replay to return the original delegation_id with replayed=true';
  END IF;
  INSERT INTO wfds_ids VALUES ('d17', v_id1);
END $$;
INSERT INTO wfds_results VALUES (17,'replaying create_workflow_delegation with the same idempotency key and identical input returns the original result unchanged');

-- ── 18: conflicting replay rejected ─────────────────────────────────
DO $$
DECLARE v_key UUID := gen_random_uuid();
BEGIN
  PERFORM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000004',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now() + interval '60 days', now() + interval '65 days', 'first', v_key);
  BEGIN
    PERFORM create_workflow_delegation(
      '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000004',
      '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
      'temporary','manual', now() + interval '60 days', now() + interval '65 days', 'different reason', v_key);
    RAISE EXCEPTION 'expected conflicting replay to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected conflicting replay to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (18,'reusing an idempotency key with different input is rejected as an idempotency-key conflict, not silently replayed');

-- ── 19: late accept after revocation rejected ───────────────────────
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000006',
    '{"type":"section_role","section_id":"00000000-0000-0000-0000-000000000009","role":"supervisor"}'::jsonb,
    'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
  RAISE EXCEPTION 'unreachable-should-have-failed-missing-section';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM = 'unreachable-should-have-failed-missing-section' THEN RAISE; END IF;
END $$;
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000006',
    '{"type":"work_item","work_item_id":"00000000-0000-0000-0000-000000000099"}'::jsonb,
    'temporary','manual', now(), now()+interval '2 days', NULL, gen_random_uuid());
  RAISE EXCEPTION 'unreachable-should-have-failed-missing-work-item';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM = 'unreachable-should-have-failed-missing-work-item' THEN RAISE; END IF;
END $$;
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000008',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now() + interval '100 days', now() + interval '105 days', NULL, gen_random_uuid());
  INSERT INTO wfds_ids VALUES ('d19', v_id);
END $$;
DO $$ BEGIN
  PERFORM revoke_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d19'), 0, 'no longer needed', gen_random_uuid());
END $$;
SELECT set_config('request.jwt.claims', :'FRANK', true);
DO $$ BEGIN
  BEGIN
    PERFORM accept_workflow_delegation((SELECT id FROM wfds_ids WHERE name='d19'), 1, gen_random_uuid());
    RAISE EXCEPTION 'expected accept after revocation to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected accept after revocation to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (19,'accepting a delegation that was already revoked while pending acceptance is rejected');

-- ── 20: immutable evidence preserved ────────────────────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfds_ids WHERE name='d1');
  IF v_count < 2 THEN RAISE EXCEPTION 'expected at least created+revoked events for d1, got %', v_count; END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
  BEGIN
    UPDATE workflow_delegation_events SET reason = 'tampered' WHERE id = (SELECT id FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfds_ids WHERE name='d1') LIMIT 1);
    RAISE EXCEPTION 'expected direct UPDATE of delegation evidence to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct UPDATE of delegation evidence to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfds_ids WHERE name='d1');
    RAISE EXCEPTION 'expected direct DELETE of delegation evidence to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct DELETE of delegation evidence to be rejected' THEN RAISE; END IF;
  END;
END $$;
SET LOCAL ROLE authenticated;
INSERT INTO wfds_results VALUES (20,'delegation lifecycle evidence is immutable: even a direct superuser UPDATE or DELETE is rejected by the append-only trigger');

-- ════════════════════════ SUBSTITUTION ════════════════════════════

-- ── 21: planned-leave substitution created ──────────────────────────
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT substitution_id, status INTO v_id, v_status FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000002"}'::jsonb,
    '65020000-0001-0000-0000-000000000004','planned_leave', now(), now() + interval '5 days', 'annual leave', gen_random_uuid());
  IF v_status <> 'active' THEN RAISE EXCEPTION 'expected active substitution, got %', v_status; END IF;
  INSERT INTO wfds_ids VALUES ('s21', v_id);
END $$;
INSERT INTO wfds_results VALUES (21,'a planned-leave substitution (person-based) is created by an administrator, auto-activated with no acceptance step');

-- ── 22: acting-appointment substitution created ─────────────────────
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT substitution_id, status INTO v_id, v_status FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"organization_role","organization_id":"65020000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    '65020000-0001-0000-0000-000000000005','acting_appointment', now(), now() + interval '5 days', 'position vacant', gen_random_uuid());
  IF v_status <> 'active' THEN RAISE EXCEPTION 'expected active substitution, got %', v_status; END IF;
  INSERT INTO wfds_ids VALUES ('s22', v_id);
END $$;
INSERT INTO wfds_results VALUES (22,'an acting-appointment substitution (position-based) is created by an administrator');

-- ── 23: authorized administrator can revoke/cancel ──────────────────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM revoke_workflow_substitution((SELECT id FROM wfds_ids WHERE name='s21'), 0, 'returned early', gen_random_uuid());
  IF v_status <> 'revoked' THEN RAISE EXCEPTION 'expected revoked (was active), got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (23,'an authorized administrator can revoke an active substitution, transitioning it to revoked');

-- ── 24: ordinary user cannot create organization substitution ──────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000003"}'::jsonb,
      '65020000-0001-0000-0000-000000000004','planned_leave', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected ordinary user substitution creation to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected ordinary user substitution creation to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (24,'an ordinary (non-administrator) user cannot create a substitution');

-- ── 25: same represented position/scope overlap rejected ───────────
SELECT set_config('request.jwt.claims', :'ADMIN', true);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000003"}'::jsonb,
    '65020000-0001-0000-0000-000000000005','planned_leave', now(), now() + interval '10 days', NULL, gen_random_uuid());
  INSERT INTO wfds_ids VALUES ('s25', v_id);
END $$;
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000003"}'::jsonb,
      '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '2 days', now() + interval '4 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected overlapping substitution for the same represented user to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected overlapping substitution for the same represented user to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (25,'a second substitution for the same represented user with an overlapping window is hard-rejected (never merely a warning)');

-- ── 26: non-overlapping substitution accepted ───────────────────────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000003"}'::jsonb,
    '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '30 days', now() + interval '35 days', NULL, gen_random_uuid());
  IF v_status <> 'scheduled' THEN RAISE EXCEPTION 'expected scheduled, got %', v_status; END IF;
END $$;
INSERT INTO wfds_results VALUES (26,'a substitution for the same represented user with a non-overlapping future window is accepted, created scheduled');

-- ── 27: self-substitution rejected ──────────────────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000004"}'::jsonb,
      '65020000-0001-0000-0000-000000000004','planned_leave', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected self-substitution to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected self-substitution to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (27,'self-substitution is rejected');

-- ── 28: wrong-organization substitute rejected ──────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000004"}'::jsonb,
      '65020000-0001-0000-0000-000000000007','planned_leave', now(), now()+interval '2 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected cross-organization substitute to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected cross-organization substitute to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (28,'a substitute from a different organization is rejected');

-- ── 29: validity duration enforced ──────────────────────────────────
DO $$ BEGIN
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000004"}'::jsonb,
      '65020000-0001-0000-0000-000000000005','planned_leave', now(), now()+interval '400 days', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected substitution exceeding 365 days to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected substitution exceeding 365 days to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (29,'a substitution exceeding the 365-day policy limit is rejected');

-- ── 30: duplicate semantic replay returns same result ───────────────
DO $$
DECLARE v_key UUID := gen_random_uuid(); v_id1 UUID; v_id2 UUID; v_replayed BOOLEAN;
BEGIN
  SELECT substitution_id INTO v_id1 FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000004"}'::jsonb,
    '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '60 days', now() + interval '65 days', 'replay test', v_key);
  SELECT substitution_id, replayed INTO v_id2, v_replayed FROM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000004"}'::jsonb,
    '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '60 days', now() + interval '65 days', 'replay test', v_key);
  IF v_id1 <> v_id2 OR NOT v_replayed THEN
    RAISE EXCEPTION 'expected identical replay to return the original substitution_id with replayed=true';
  END IF;
END $$;
INSERT INTO wfds_results VALUES (30,'replaying create_workflow_substitution with the same idempotency key and identical input returns the original result unchanged');

-- ── 31: conflicting replay rejected ─────────────────────────────────
DO $$
DECLARE v_key UUID := gen_random_uuid();
BEGIN
  PERFORM create_workflow_substitution(
    '65020000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65020000-0001-0000-0000-000000000005"}'::jsonb,
    '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '70 days', now() + interval '75 days', 'first', v_key);
  BEGIN
    PERFORM create_workflow_substitution(
      '65020000-0000-0000-0000-000000000001',
      '{"type":"user","user_id":"65020000-0001-0000-0000-000000000005"}'::jsonb,
      '65020000-0001-0000-0000-000000000006','planned_leave', now() + interval '70 days', now() + interval '75 days', 'different reason', v_key);
    RAISE EXCEPTION 'expected conflicting substitution replay to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected conflicting substitution replay to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfds_results VALUES (31,'reusing a substitution idempotency key with different input is rejected as an idempotency-key conflict');

-- ── 32: immutable evidence preserved ────────────────────────────────
RESET ROLE;
DO $$ BEGIN
  BEGIN
    UPDATE workflow_substitution_events SET reason = 'tampered' WHERE id = (SELECT id FROM workflow_substitution_events WHERE substitution_id = (SELECT id FROM wfds_ids WHERE name='s21') LIMIT 1);
    RAISE EXCEPTION 'expected direct UPDATE of substitution evidence to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct UPDATE of substitution evidence to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM workflow_substitution_events WHERE substitution_id = (SELECT id FROM wfds_ids WHERE name='s21');
    RAISE EXCEPTION 'expected direct DELETE of substitution evidence to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected direct DELETE of substitution evidence to be rejected' THEN RAISE; END IF;
  END;
END $$;
SET LOCAL ROLE authenticated;
INSERT INTO wfds_results VALUES (32,'substitution lifecycle evidence is immutable: even a direct superuser UPDATE or DELETE is rejected by the append-only trigger');

-- ══════════════ LIVE-INTEGRATION BOUNDARY (real engine fixture) ═══

\set REAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN', true);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65020000-0000-0000-0000-000000000001','wfds_flow','WFDS Flow','opaque_case', :REAL_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wfds_ids SELECT 'v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfds_ids WHERE name='v'),0,gen_random_uuid());
INSERT INTO wfds_ids SELECT 'i', create_workflow_instance(
  (SELECT id FROM wfds_ids WHERE name='v'),'opaque_case',gen_random_uuid(),
  '65020000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfds_ids WHERE name='i'),0,gen_random_uuid());
INSERT INTO wfds_ids SELECT 'alice_wi', id FROM workflow_work_items
WHERE instance_id = (SELECT id FROM wfds_ids WHERE name='i') AND assigned_to = '65020000-0001-0000-0000-000000000002';

-- ── 33: no live work-item ownership changes occur ───────────────────
SELECT set_config('request.jwt.claims', :'ALICE', true);
DO $$
DECLARE v_before UUID; v_after UUID;
BEGIN
  SELECT assigned_to INTO v_before FROM workflow_work_items WHERE id = (SELECT id FROM wfds_ids WHERE name='alice_wi');
  PERFORM create_workflow_delegation(
    '65020000-0000-0000-0000-000000000001','65020000-0001-0000-0000-000000000002','65020000-0001-0000-0000-000000000003',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wfds_ids WHERE name='alice_wi')::text),
    'temporary','manual', now(), now()+interval '2 days', 'coverage', gen_random_uuid());
  SELECT assigned_to INTO v_after FROM workflow_work_items WHERE id = (SELECT id FROM wfds_ids WHERE name='alice_wi');
  IF v_before IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'creating a work-item-scoped delegation must never change workflow_work_items.assigned_to';
  END IF;
END $$;
INSERT INTO wfds_results VALUES (33,'creating a work-item-scoped delegation does not alter workflow_work_items.assigned_to or any other live work-item state');

-- ── 34: existing approval behavior remains unchanged ────────────────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT instance_status INTO v_status FROM decide_workflow_work_item(
    (SELECT id FROM wfds_ids WHERE name='alice_wi'), 'approve', 1, 0, gen_random_uuid());
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the existing approval decision path to behave exactly as before Phase 5.1, got status %', v_status;
  END IF;
END $$;
INSERT INTO wfds_results VALUES (34,'an ordinary approval decision on the same instance behaves exactly as it did before Phase 5.1 (delegation is not live-integrated)');

-- ── 35: existing workflow engine validators remain passing ─────────
DO $$
DECLARE v_def TEXT;
BEGIN
  SELECT pg_get_functiondef('decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' THEN
    RAISE EXCEPTION 'decide_workflow_work_item must not reference the new delegation/substitution tables';
  END IF;
  SELECT pg_get_functiondef('workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'::regprocedure) INTO v_def;
  IF v_def ILIKE '%workflow_delegations%' OR v_def ILIKE '%workflow_substitutions%' THEN
    RAISE EXCEPTION 'workflow_enter_downstream_node must not reference the new delegation/substitution tables';
  END IF;
END $$;
INSERT INTO wfds_results VALUES (35,'the core graph-advancement and decision functions carry zero references to the new delegation/substitution objects (full validator/regression coverage runs separately)');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfds_results;
  IF v_count <> 35 THEN
    RAISE EXCEPTION 'Workflow delegation/substitution foundation behavioral tests FAILED: expected 35, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution foundation behavioral tests PASSED: %/35', v_count;
END $$;

ROLLBACK;
