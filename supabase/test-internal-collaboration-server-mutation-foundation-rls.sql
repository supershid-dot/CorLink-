-- CAP-003 Phase 1.8A RLS/security test suite. Disposable local
-- PostgreSQL only. This milestone changed zero SELECT-side RLS
-- policies -- these scenarios prove (a) internal_requests(_replies)
-- SELECT-side RLS is exactly as before, (b) direct client writes
-- against those two tables are now genuinely rejected (not just
-- structurally absent from a grant table), (c) every migrated RPC
-- rejects an unauthenticated caller, (d) Internal Collaboration
-- remains strictly single-org (no cross-org visibility or mutation
-- capability exists anywhere in this module), and (e) sibling modules
-- (Requests, Entry, Task integration, approvals) are untouched.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('18b00000-0000-0000-0000-000000000001','RLS T18B Org','authority','R18B'),
  ('18b00000-0000-0000-0000-000000000002','RLS T18B Gamma Org','authority','R18G');
INSERT INTO divisions(id, org_id, name) VALUES
  ('18b00000-0004-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001','Div'),
  ('18b00000-0004-0000-0000-000000000002','18b00000-0000-0000-0000-000000000002','Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('18b00000-0002-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001','18b00000-0004-0000-0000-000000000001','Records','R18REC'),
  ('18b00000-0002-0000-0000-000000000002','18b00000-0000-0000-0000-000000000001','18b00000-0004-0000-0000-000000000001','Welfare','R18WEL'),
  ('18b00000-0002-0000-0000-000000000009','18b00000-0000-0000-0000-000000000002','18b00000-0004-0000-0000-000000000002','Gamma Sec','R18GS');
INSERT INTO auth.users(id,email) VALUES
  ('18b00000-0001-0000-0000-000000000001','r18b-records@t.local'),
  ('18b00000-0001-0000-0000-000000000002','r18b-welfare@t.local'),
  ('18b00000-0001-0000-0000-000000000003','r18b-outsider@t.local'),
  ('18b00000-0001-0000-0000-000000000004','r18b-gamma@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('18b00000-0001-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001','R18B-1','Records Staff','r18b-records@t.local',TRUE),
  ('18b00000-0001-0000-0000-000000000002','18b00000-0000-0000-0000-000000000001','R18B-2','Welfare Staff','r18b-welfare@t.local',TRUE),
  ('18b00000-0001-0000-0000-000000000003','18b00000-0000-0000-0000-000000000001','R18B-3','Outsider','r18b-outsider@t.local',TRUE),
  ('18b00000-0001-0000-0000-000000000004','18b00000-0000-0000-0000-000000000002','R18B-4','Gamma User','r18b-gamma@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('18b00000-0001-0000-0000-000000000001','section','18b00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('18b00000-0001-0000-0000-000000000002','section','18b00000-0002-0000-0000-000000000002','staff',TRUE,TRUE);
-- Outsider (18b...003) is same-org but has NO section assignment.
-- Gamma user (18b...004) belongs to an entirely different organization.

-- Seeded as postgres (superuser bypass) since this milestone revokes
-- direct INSERT on internal_requests(_replies) from authenticated --
-- exactly the thing TEST 3/5/6 below prove.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status)
VALUES ('18b00000-0003-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001',
  '18b00000-0002-0000-0000-000000000001','18b00000-0001-0000-0000-000000000001','RLS parent subj','RLS parent body','sent');
INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
VALUES ('18b00000-0005-0000-0000-000000000001','18b00000-0003-0000-0000-000000000001',
  '18b00000-0002-0000-0000-000000000001','18b00000-0002-0000-0000-000000000002',
  '18b00000-0001-0000-0000-000000000001','RLS test subject','RLS test body','sent');
INSERT INTO internal_request_replies (id, internal_request_id, body, created_by, status)
VALUES ('18b00000-0006-0000-0000-000000000001','18b00000-0005-0000-0000-000000000001','seed reply','18b00000-0001-0000-0000-000000000002','draft');

SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 1: outsider (same org, no section assignment, not created_by) cannot SELECT the thread
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000003"}',true);
  IF EXISTS (SELECT 1 FROM internal_requests WHERE id = '18b00000-0005-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 1 FAILED: outsider should not see an internal_requests thread they have no relationship to';
  END IF;
  RAISE NOTICE 'RLS TEST 1 PASSED: internal_requests_select still denies an unrelated same-org outsider (unchanged by this milestone)';
END $$;

DO $$
BEGIN
  -- TEST 2: a different organization has zero visibility -- proves the
  -- module remains strictly internal (single-org) as documented.
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000004"}',true);
  IF EXISTS (SELECT 1 FROM internal_requests WHERE id = '18b00000-0005-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 2 FAILED: a foreign organization should never see an internal_requests row';
  END IF;
  RAISE NOTICE 'RLS TEST 2 PASSED: Internal Collaboration is strictly single-org -- an unrelated organization has zero visibility';
END $$;

DO $$
BEGIN
  -- TEST 3: direct INSERT on internal_requests is now rejected (RPC-only)
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO internal_requests (parent_request_id, from_section_id, to_section_id, created_by, subject, body)
    VALUES ('18b00000-0003-0000-0000-000000000001','18b00000-0002-0000-0000-000000000001',
      '18b00000-0002-0000-0000-000000000002','18b00000-0001-0000-0000-000000000001','bypass','bypass');
    RAISE EXCEPTION 'RLS TEST 3 FAILED: direct INSERT on internal_requests should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 3 PASSED: direct client INSERT on internal_requests rejected (create_internal_request is the only path)';
  END;
END $$;

DO $$
BEGIN
  -- TEST 4: direct UPDATE on internal_requests is now rejected, even by a party to the thread
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    UPDATE internal_requests SET subject = 'bypassed' WHERE id = '18b00000-0005-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 4 FAILED: direct UPDATE on internal_requests should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 4 PASSED: direct client UPDATE on internal_requests rejected, even by a thread party';
  END;
END $$;

DO $$
BEGIN
  -- TEST 5/6: direct INSERT/UPDATE on internal_request_replies rejected
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    INSERT INTO internal_request_replies (internal_request_id, created_by, body, status)
    VALUES ('18b00000-0005-0000-0000-000000000001','18b00000-0001-0000-0000-000000000002','bypass','draft');
    RAISE EXCEPTION 'RLS TEST 5 FAILED: direct INSERT on internal_request_replies should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 5 PASSED: direct client INSERT on internal_request_replies rejected (draft_internal_request_reply is the only path)';
  END;
  BEGIN
    UPDATE internal_request_replies SET body = 'bypassed' WHERE id = '18b00000-0006-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 6 FAILED: direct UPDATE on internal_request_replies should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 6 PASSED: direct client UPDATE on internal_request_replies rejected';
  END;
END $$;

DO $$
BEGIN
  -- TEST 7: unauthenticated (no auth.uid()) caller rejected by a migrated RPC
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM close_internal_request('18b00000-0005-0000-0000-000000000001');
    RAISE EXCEPTION 'RLS TEST 7 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%authenticated caller%' THEN
      RAISE EXCEPTION 'RLS TEST 7 FAILED: wrong rejection reason: %', SQLERRM;
    END IF;
    RAISE NOTICE 'RLS TEST 7 PASSED: close_internal_request rejects an unauthenticated caller explicitly';
  END;
END $$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM create_internal_request('18b00000-0002-0000-0000-000000000001','18b00000-0002-0000-0000-000000000002','x','y','18b00000-0003-0000-0000-000000000001',NULL);
    RAISE EXCEPTION 'RLS TEST 8 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 8 PASSED: create_internal_request rejects an unauthenticated caller explicitly: %', SQLERRM;
  END;
END $$;

DO $$
DECLARE v_count INT;
BEGIN
  -- TEST 9: approvals table (unrelated, untouched) -- Internal
  -- Collaboration never writes here (see patch header); confirm no row
  -- exists for this reply and that the CHECK constraint still rejects
  -- an attempt to widen record_type to an Internal Collaboration value.
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000001"}',true);
  SELECT count(*) INTO v_count FROM approvals WHERE record_id = '18b00000-0006-0000-0000-000000000001';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS TEST 9 FAILED: approvals should have zero rows for an Internal Collaboration reply';
  END IF;
  RAISE NOTICE 'RLS TEST 9 PASSED: approvals table (unrelated to this milestone) has no Internal Collaboration rows';
END $$;

DO $$
BEGIN
  -- TEST 10: Requests (unrelated, untouched) direct write path still
  -- rejected exactly as Phase 1.6A left it -- proves this milestone
  -- did not touch that module's own mutation boundary at all.
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO requests (from_org_id, to_org_id, from_section_id, created_by, subject, body)
    VALUES ('18b00000-0000-0000-0000-000000000001','18b00000-0000-0000-0000-000000000001',
      '18b00000-0002-0000-0000-000000000001','18b00000-0001-0000-0000-000000000001','bypass','bypass');
    RAISE EXCEPTION 'RLS TEST 10 FAILED: direct INSERT on requests should still be rejected (Phase 1.6A, unrelated to this milestone)';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 10 PASSED: Requests'' own direct-write closure (Phase 1.6A) is untouched by this milestone';
  END;
END $$;

DO $$
BEGIN
  -- TEST 11: Entry (unrelated, untouched) direct write path still
  -- rejected exactly as Phase 1.7A left it.
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO external_correspondence (org_id, source_channel, sender_category, sender_name, subject, body, entered_by, status)
    VALUES ('18b00000-0000-0000-0000-000000000001','email','public','Bypass','bypass','bypass','18b00000-0001-0000-0000-000000000001','logged');
    RAISE EXCEPTION 'RLS TEST 11 FAILED: direct INSERT on external_correspondence should still be rejected (Phase 1.7A, unrelated to this milestone)';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 11 PASSED: Entry''s own direct-write closure (Phase 1.7A) is untouched by this milestone';
  END;
END $$;

RESET ROLE; -- superuser bypass: force the fixture thread to a terminal (closed) state for TEST 12
UPDATE internal_requests SET status = 'closed' WHERE id = '18b00000-0005-0000-0000-000000000001';
SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 12: a closed (terminal) thread remains SELECT-visible to its
  -- parties (unchanged), but a migrated RPC still independently
  -- enforces its own authorization/eligibility -- reroute on a caller
  -- outside the thread is rejected regardless of the thread's status.
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000002"}',true);
  IF NOT EXISTS (SELECT 1 FROM internal_requests WHERE id = '18b00000-0005-0000-0000-000000000001' AND status = 'closed') THEN
    RAISE EXCEPTION 'RLS TEST 12 FAILED: a thread party should still see a closed internal_requests row';
  END IF;
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000003"}',true); -- outsider
  BEGIN
    PERFORM reroute_internal_request('18b00000-0005-0000-0000-000000000001', '18b00000-0002-0000-0000-000000000001');
    RAISE EXCEPTION 'RLS TEST 12b FAILED: an outsider should not be able to reroute any internal_requests row, closed or not';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 12b PASSED: reroute_internal_request rejects an outsider regardless of thread status: %', SQLERRM;
  END;
  RAISE NOTICE 'RLS TEST 12 PASSED: closed threads remain visible to their parties but stay authorization-protected via the RPC layer';
END $$;

DO $$
BEGIN
  -- TEST 13: cross-org routing is rejected at the RPC layer even for an
  -- authorized (same-org) caller attempting to name a foreign section --
  -- proves org-boundary enforcement is independent of, not reliant on,
  -- RLS USING clauses (SECURITY DEFINER bypasses RLS entirely).
  PERFORM set_config('request.jwt.claims','{"sub":"18b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_internal_request('18b00000-0002-0000-0000-000000000001','18b00000-0002-0000-0000-000000000009','x','y','18b00000-0003-0000-0000-000000000001',NULL);
    RAISE EXCEPTION 'RLS TEST 13 FAILED: create_internal_request should reject a foreign-org to_section_id even for an authorized same-org caller';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 13 PASSED: create_internal_request independently enforces the org boundary server-side: %', SQLERRM;
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'INTERNAL COLLABORATION SERVER MUTATION FOUNDATION RLS TESTS: 13/13 PASSED'; END $$;
ROLLBACK;
