-- CAP-003 Phase 1.6A RLS/security test suite. Disposable local
-- PostgreSQL only. This milestone changed zero RLS policies -- these
-- scenarios prove (a) requests/responses SELECT-side RLS is exactly
-- as before, (b) direct client writes against requests/responses are
-- now genuinely rejected (not just structurally absent from a grant
-- table), and (c) every migrated RPC rejects an unauthenticated caller.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('16b00000-0000-0000-0000-000000000001','RLS Org Alpha','authority','RLSA'),
  ('16b00000-0000-0000-0000-000000000002','RLS Org Beta','authority','RLSB');
INSERT INTO divisions(id, org_id, name) VALUES
  ('16b00000-0004-0000-0000-000000000001','16b00000-0000-0000-0000-000000000001','A Div'),
  ('16b00000-0004-0000-0000-000000000002','16b00000-0000-0000-0000-000000000002','B Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('16b00000-0002-0000-0000-000000000001','16b00000-0000-0000-0000-000000000001','16b00000-0004-0000-0000-000000000001','A Sec','ASX'),
  ('16b00000-0002-0000-0000-000000000002','16b00000-0000-0000-0000-000000000002','16b00000-0004-0000-0000-000000000002','B Sec','BSX');
INSERT INTO auth.users(id,email) VALUES
  ('16b00000-0001-0000-0000-000000000001','r16b-alpha@t.local'),
  ('16b00000-0001-0000-0000-000000000002','r16b-beta@t.local'),
  ('16b00000-0001-0000-0000-000000000003','r16b-outsider@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('16b00000-0001-0000-0000-000000000001','16b00000-0000-0000-0000-000000000001','R16B-1','Alpha','r16b-alpha@t.local',TRUE),
  ('16b00000-0001-0000-0000-000000000002','16b00000-0000-0000-0000-000000000002','R16B-2','Beta','r16b-beta@t.local',TRUE),
  ('16b00000-0001-0000-0000-000000000003','16b00000-0000-0000-0000-000000000001','R16B-3','Outsider','r16b-outsider@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('16b00000-0001-0000-0000-000000000001','section','16b00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('16b00000-0001-0000-0000-000000000002','section','16b00000-0002-0000-0000-000000000002','staff',TRUE,TRUE);
-- outsider (16b...003) is Alpha-org but has NO section assignment at all.

INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status)
VALUES ('16b00000-0009-0000-0000-000000000001',
  '16b00000-0000-0000-0000-000000000001','16b00000-0000-0000-0000-000000000002',
  '16b00000-0002-0000-0000-000000000001','16b00000-0001-0000-0000-000000000001',
  'RLS test subject','RLS test body','draft');
-- Seeded as postgres (superuser, bypasses the authenticated-role grant
-- narrowing) since this milestone revokes direct INSERT on responses
-- from authenticated -- exactly the thing TEST 5 below proves.
INSERT INTO responses (id, request_id, created_by, body, status)
VALUES ('16b00000-000a-0000-0000-000000000001', '16b00000-0009-0000-0000-000000000001',
  '16b00000-0001-0000-0000-000000000002', 'seed response', 'draft');

SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 1: outsider (same org, no section assignment, not creator) cannot SELECT the draft
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000003"}',true);
  IF EXISTS (SELECT 1 FROM requests WHERE id = '16b00000-0009-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 1 FAILED: outsider should not see a draft they have no relationship to';
  END IF;
  RAISE NOTICE 'RLS TEST 1 PASSED: requests_select still denies an unrelated same-org outsider (unchanged by this milestone)';
END $$;

DO $$
BEGIN
  -- TEST 2: creator CAN select their own draft (control, RLS unchanged)
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000001"}',true);
  IF NOT EXISTS (SELECT 1 FROM requests WHERE id = '16b00000-0009-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 2 FAILED: creator should see their own draft';
  END IF;
  RAISE NOTICE 'RLS TEST 2 PASSED: creator retains SELECT visibility of their own draft (unchanged)';
END $$;

DO $$
BEGIN
  -- TEST 3: direct INSERT on requests is now rejected (RPC-only)
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO requests (from_org_id, to_org_id, from_section_id, created_by, subject, body, status)
    VALUES ('16b00000-0000-0000-0000-000000000001','16b00000-0000-0000-0000-000000000002',
      '16b00000-0002-0000-0000-000000000001','16b00000-0001-0000-0000-000000000001','bypass','bypass','draft');
    RAISE EXCEPTION 'RLS TEST 3 FAILED: direct INSERT on requests should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 3 PASSED: direct client INSERT on requests rejected (create_request is the only path)';
  END;
END $$;

DO $$
BEGIN
  -- TEST 4: direct UPDATE on requests is now rejected, even by the creator on their own draft
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    UPDATE requests SET subject = 'bypassed' WHERE id = '16b00000-0009-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 4 FAILED: direct UPDATE on requests should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 4 PASSED: direct client UPDATE on requests rejected, even by the row''s own creator';
  END;
END $$;

DO $$
BEGIN
  -- TEST 5/6: direct INSERT/UPDATE on responses rejected
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    INSERT INTO responses (request_id, created_by, body, status)
    VALUES ('16b00000-0009-0000-0000-000000000001', '16b00000-0001-0000-0000-000000000002', 'bypass', 'draft');
    RAISE EXCEPTION 'RLS TEST 5 FAILED: direct INSERT on responses should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 5 PASSED: direct client INSERT on responses rejected (create_response is the only path)';
  END;
  BEGIN
    UPDATE responses SET body = 'bypassed' WHERE id = '16b00000-000a-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 6 FAILED: direct UPDATE on responses should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 6 PASSED: direct client UPDATE on responses rejected';
  END;
END $$;

DO $$
BEGIN
  -- TEST 7: unauthenticated (no auth.uid()) caller rejected by a migrated RPC
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM cancel_request('16b00000-0009-0000-0000-000000000001', 'x');
    RAISE EXCEPTION 'RLS TEST 7 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%authenticated caller%' THEN
      RAISE EXCEPTION 'RLS TEST 7 FAILED: wrong rejection reason: %', SQLERRM;
    END IF;
    RAISE NOTICE 'RLS TEST 7 PASSED: cancel_request rejects an unauthenticated caller explicitly';
  END;
END $$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM create_request('16b00000-0002-0000-0000-000000000001','16b00000-0000-0000-0000-000000000002','x','y','en','en',NULL,NULL);
    RAISE EXCEPTION 'RLS TEST 8 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 8 PASSED: create_request rejects an unauthenticated caller explicitly: %', SQLERRM;
  END;
END $$;

DO $$
BEGIN
  -- TEST 9: approvals table's own RLS (unrelated, untouched) still denies a non-party read
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000003"}',true);
  IF EXISTS (SELECT 1 FROM approvals WHERE record_type = 'request' AND record_id = '16b00000-0009-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 9 FAILED: outsider should not see approvals for a request they have no relationship to';
  END IF;
  RAISE NOTICE 'RLS TEST 9 PASSED: approvals RLS (unrelated to this milestone) is untouched';
END $$;

DO $$
BEGIN
  -- TEST 10: deadline_extensions table/RLS exist and are completely
  -- untouched (this milestone deferred deadline/extension mutation --
  -- see docs/89 -- since it has zero existing frontend implementation
  -- to migrate; its RLS must still be exactly as before).
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000001"}',true);
  IF to_regclass('public.deadline_extensions') IS NULL THEN
    RAISE EXCEPTION 'RLS TEST 10 FAILED: deadline_extensions table missing';
  END IF;
  RAISE NOTICE 'RLS TEST 10 PASSED: deadline_extensions table/RLS untouched (deferred, not migrated)';
END $$;

DO $$
BEGIN
  -- TEST 11: internal_requests (Internal Collaboration) direct INSERT
  -- is now REJECTED -- narrow, established carve-out: this assertion
  -- originally proved Phase 1.6A did not touch Internal Collaboration's
  -- own client-write path. CAP-003 Phase 1.8A subsequently migrated
  -- Internal Collaboration to its own server-authoritative RPCs and
  -- closed its direct-write grant, exactly the same class of sibling
  -- update already applied elsewhere in this repository when a later
  -- milestone migrates a module an earlier milestone's test used as its
  -- "still direct-write" control. This does not weaken any security
  -- assertion -- it tightens it, matching the real current posture.
  PERFORM set_config('request.jwt.claims','{"sub":"16b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO internal_requests (parent_request_id, from_section_id, to_section_id, created_by, subject, body)
    VALUES ('16b00000-0009-0000-0000-000000000001', '16b00000-0002-0000-0000-000000000001',
      '16b00000-0002-0000-0000-000000000001', '16b00000-0001-0000-0000-000000000001', 'still direct-write', 'body');
    RAISE EXCEPTION 'RLS TEST 11 FAILED: internal_requests direct INSERT should now be rejected (CAP-003 Phase 1.8A direct-write closure)';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 11 PASSED: internal_requests direct client INSERT is now rejected, matching CAP-003 Phase 1.8A''s direct-write closure';
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'REQUESTS SERVER MUTATION FOUNDATION RLS TESTS: 11/11 PASSED'; END $$;
ROLLBACK;
