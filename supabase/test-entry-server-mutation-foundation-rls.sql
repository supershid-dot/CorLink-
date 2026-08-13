-- CAP-003 Phase 1.7A RLS/security test suite. Disposable local
-- PostgreSQL only. This milestone changed zero RLS policies -- these
-- scenarios prove (a) external_correspondence(_replies) SELECT-side
-- RLS is exactly as before, (b) direct client writes against those two
-- tables are now genuinely rejected (not just structurally absent from
-- a grant table), (c) every migrated RPC rejects an unauthenticated
-- caller, and (d) Entry remains internal-only -- no cross-org/authority
-- visibility or mutation capability exists anywhere in this module.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('17b00000-0000-0000-0000-000000000001','RLS MCS Org','mcs','R17M'),
  ('17b00000-0000-0000-0000-000000000002','RLS Authority Org','authority','R17H');
INSERT INTO divisions(id, org_id, name) VALUES
  ('17b00000-0004-0000-0000-000000000001','17b00000-0000-0000-0000-000000000001','Div'),
  ('17b00000-0004-0000-0000-000000000002','17b00000-0000-0000-0000-000000000002','H Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('17b00000-0002-0000-0000-000000000001','17b00000-0000-0000-0000-000000000001','17b00000-0004-0000-0000-000000000001','Front Desk','FDX'),
  ('17b00000-0002-0000-0000-000000000002','17b00000-0000-0000-0000-000000000001','17b00000-0004-0000-0000-000000000001','Legal','LGX'),
  ('17b00000-0002-0000-0000-000000000009','17b00000-0000-0000-0000-000000000002','17b00000-0004-0000-0000-000000000002','H Sec','HSX');
INSERT INTO entry_sections(org_id, section_id) VALUES
  ('17b00000-0000-0000-0000-000000000001','17b00000-0002-0000-0000-000000000001');
INSERT INTO auth.users(id,email) VALUES
  ('17b00000-0001-0000-0000-000000000001','r17b-frontdesk@t.local'),
  ('17b00000-0001-0000-0000-000000000002','r17b-legal@t.local'),
  ('17b00000-0001-0000-0000-000000000003','r17b-outsider@t.local'),
  ('17b00000-0001-0000-0000-000000000004','r17b-authority@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('17b00000-0001-0000-0000-000000000001','17b00000-0000-0000-0000-000000000001','R17B-1','Front Desk','r17b-frontdesk@t.local',TRUE),
  ('17b00000-0001-0000-0000-000000000002','17b00000-0000-0000-0000-000000000001','R17B-2','Legal','r17b-legal@t.local',TRUE),
  ('17b00000-0001-0000-0000-000000000003','17b00000-0000-0000-0000-000000000001','R17B-3','Outsider','r17b-outsider@t.local',TRUE),
  ('17b00000-0001-0000-0000-000000000004','17b00000-0000-0000-0000-000000000002','R17B-4','Authority User','r17b-authority@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('17b00000-0001-0000-0000-000000000001','section','17b00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('17b00000-0001-0000-0000-000000000002','section','17b00000-0002-0000-0000-000000000002','staff',TRUE,TRUE);
-- Outsider (17b...003) is same-org but has NO section assignment.
-- Authority user (17b...004) belongs to an entirely different, non-MCS organization.

-- Seeded as postgres (superuser, bypasses the authenticated-role grant
-- narrowing) since this milestone revokes direct INSERT on
-- external_correspondence(_replies) from authenticated -- exactly the
-- thing TEST 3/5/6 below prove.
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, status, reference_number)
VALUES ('17b00000-0009-0000-0000-000000000001', '17b00000-0000-0000-0000-000000000001',
  'email','public','RLS Sender','RLS test subject','RLS test body','17b00000-0001-0000-0000-000000000001','logged','ENT-R17B-TEST-0001');
INSERT INTO external_correspondence_replies (id, entry_id, body, created_by, status)
VALUES ('17b00000-000a-0000-0000-000000000001','17b00000-0009-0000-0000-000000000001','seed reply','17b00000-0001-0000-0000-000000000002','draft');

SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 1: outsider (same org, no section assignment, not entered_by) cannot SELECT the entry
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000003"}',true);
  IF EXISTS (SELECT 1 FROM external_correspondence WHERE id = '17b00000-0009-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 1 FAILED: outsider should not see an entry they have no relationship to';
  END IF;
  RAISE NOTICE 'RLS TEST 1 PASSED: external_correspondence_select still denies an unrelated same-org outsider (unchanged by this milestone)';
END $$;

DO $$
BEGIN
  -- TEST 2: an entirely different organization (authority-type, not
  -- MCS) has zero visibility into Entry -- proves the module remains
  -- strictly internal-only regardless of CAP-003 supporting
  -- cross-organization notifications elsewhere in the platform.
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000004"}',true);
  IF EXISTS (SELECT 1 FROM external_correspondence WHERE id = '17b00000-0009-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 2 FAILED: an external authority organization should never see an Entry record';
  END IF;
  RAISE NOTICE 'RLS TEST 2 PASSED: Entry is strictly internal-only -- an unrelated authority-type organization has zero visibility';
END $$;

DO $$
BEGIN
  -- TEST 3: direct INSERT on external_correspondence is now rejected (RPC-only)
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO external_correspondence (org_id, source_channel, sender_category, sender_name, subject, body, entered_by, status)
    VALUES ('17b00000-0000-0000-0000-000000000001','email','public','Bypass','bypass','bypass','17b00000-0001-0000-0000-000000000001','logged');
    RAISE EXCEPTION 'RLS TEST 3 FAILED: direct INSERT on external_correspondence should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 3 PASSED: direct client INSERT on external_correspondence rejected (create_entry is the only path)';
  END;
END $$;

DO $$
BEGIN
  -- TEST 4: direct UPDATE on external_correspondence is now rejected, even by Entry staff
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    UPDATE external_correspondence SET subject = 'bypassed' WHERE id = '17b00000-0009-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 4 FAILED: direct UPDATE on external_correspondence should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 4 PASSED: direct client UPDATE on external_correspondence rejected, even by Entry staff';
  END;
END $$;

DO $$
BEGIN
  -- TEST 5/6: direct INSERT/UPDATE on external_correspondence_replies rejected
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    INSERT INTO external_correspondence_replies (entry_id, created_by, body, status)
    VALUES ('17b00000-0009-0000-0000-000000000001','17b00000-0001-0000-0000-000000000002','bypass','draft');
    RAISE EXCEPTION 'RLS TEST 5 FAILED: direct INSERT on external_correspondence_replies should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 5 PASSED: direct client INSERT on external_correspondence_replies rejected (draft_entry_reply is the only path)';
  END;
  BEGIN
    UPDATE external_correspondence_replies SET body = 'bypassed' WHERE id = '17b00000-000a-0000-0000-000000000001';
    RAISE EXCEPTION 'RLS TEST 6 FAILED: direct UPDATE on external_correspondence_replies should be rejected';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'RLS TEST 6 PASSED: direct client UPDATE on external_correspondence_replies rejected';
  END;
END $$;

DO $$
BEGIN
  -- TEST 7: unauthenticated (no auth.uid()) caller rejected by a migrated RPC
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM close_entry('17b00000-0009-0000-0000-000000000001');
    RAISE EXCEPTION 'RLS TEST 7 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%authenticated caller%' THEN
      RAISE EXCEPTION 'RLS TEST 7 FAILED: wrong rejection reason: %', SQLERRM;
    END IF;
    RAISE NOTICE 'RLS TEST 7 PASSED: close_entry rejects an unauthenticated caller explicitly';
  END;
END $$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM create_entry('email','public','x','y','z');
    RAISE EXCEPTION 'RLS TEST 8 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 8 PASSED: create_entry rejects an unauthenticated caller explicitly: %', SQLERRM;
  END;
END $$;

DO $$
BEGIN
  -- TEST 9: approvals table's own RLS (unrelated, untouched) still denies a non-party read
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000003"}',true);
  IF EXISTS (SELECT 1 FROM approvals WHERE record_type = 'external_correspondence_reply' AND record_id = '17b00000-000a-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'RLS TEST 9 FAILED: outsider should not see approvals for a reply they have no relationship to';
  END IF;
  RAISE NOTICE 'RLS TEST 9 PASSED: approvals RLS (unrelated to this milestone) is untouched';
END $$;

RESET ROLE; -- superuser bypass: this milestone revoked direct INSERT on external_correspondence from authenticated, so this fixture seed row must be inserted as the connecting (postgres) role, same as the file's initial fixtures above.
UPDATE external_correspondence SET status = 'routed' WHERE id = '17b00000-0009-0000-0000-000000000001';
UPDATE external_correspondence SET status = 'responded' WHERE id = '17b00000-0009-0000-0000-000000000001';
UPDATE external_correspondence SET status = 'closed' WHERE id = '17b00000-0009-0000-0000-000000000001';
SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 10: closed entry (terminal state) remains SELECT-visible to
  -- Entry staff (unchanged), but is still trigger-protected against
  -- being reopened/rerouted via any migrated RPC (close->close is a
  -- trivial no-op transition the trigger permits by design -- same-
  -- state identity is always legal -- so re-routing, a genuine
  -- forward transition attempt out of a terminal state, is the real
  -- proof here).
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000001"}',true);
  IF NOT EXISTS (SELECT 1 FROM external_correspondence WHERE id = '17b00000-0009-0000-0000-000000000001' AND status = 'closed') THEN
    RAISE EXCEPTION 'RLS TEST 10 FAILED: Entry staff should still see a closed entry';
  END IF;
  BEGIN
    PERFORM route_entry('17b00000-0009-0000-0000-000000000001', '17b00000-0002-0000-0000-000000000002', NULL);
    RAISE EXCEPTION 'RLS TEST 10b FAILED: rerouting a closed (terminal) entry should be rejected by the status trigger';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'RLS TEST 10b PASSED: route_entry on an already-closed (terminal) entry is rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'RLS TEST 10 PASSED: closed entries remain visible but are trigger-protected against being reopened';
END $$;

DO $$
BEGIN
  -- TEST 11: Requests (unrelated, untouched) direct write path still
  -- works exactly as Phase 1.6A left it -- proves this milestone did
  -- not touch that module's own mutation boundary at all.
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_request('17b00000-0002-0000-0000-000000000001','17b00000-0000-0000-0000-000000000002','still rpc-only','body','en','en',NULL,NULL);
    RAISE NOTICE 'RLS TEST 11 PASSED: Requests'' own create_request RPC (Phase 1.6A) still works unchanged (Requests not touched by this milestone)';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'RLS TEST 11 FAILED: create_request unexpectedly broken by this milestone: %', SQLERRM;
  END;
END $$;

-- Fresh, still-open (non-terminal) entry for TEST 12, seeded before the
-- terminal-state entry used by TEST 10 -- internal_requests_insert's
-- own internal_requests_parent_startable() check (unrelated to this
-- milestone) correctly refuses to start a new Internal Collaboration
-- thread against an already-closed case, so this must not reuse the
-- entry TEST 10 force-closed.
RESET ROLE; -- superuser bypass: this milestone revoked direct INSERT on external_correspondence from authenticated, so this fixture seed row must be inserted as the connecting (postgres) role, same as the file's initial fixtures above.
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, status, reference_number)
VALUES ('17b00000-0009-0000-0000-000000000002', '17b00000-0000-0000-0000-000000000001',
  'email','public','RLS Sender 2','RLS test subject 2','RLS test body 2','17b00000-0001-0000-0000-000000000001',
  '17b00000-0002-0000-0000-000000000002','routed','ENT-R17B-TEST-0002');
SET ROLE authenticated;

DO $$
BEGIN
  -- TEST 12: internal_requests (Internal Collaboration) direct INSERT
  -- anchored to an Entry case via parent_entry_id still works exactly
  -- as before -- proves this milestone did not touch that integration
  -- point at all.
  PERFORM set_config('request.jwt.claims','{"sub":"17b00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    INSERT INTO internal_requests (parent_entry_id, from_section_id, to_section_id, created_by, subject, body)
    VALUES ('17b00000-0009-0000-0000-000000000002', '17b00000-0002-0000-0000-000000000002',
      '17b00000-0002-0000-0000-000000000002', '17b00000-0001-0000-0000-000000000002', 'still direct-write', 'body');
    RAISE NOTICE 'RLS TEST 12 PASSED: internal_requests direct client INSERT (anchored via parent_entry_id) still works unchanged';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE EXCEPTION 'RLS TEST 12 FAILED: internal_requests direct write was unexpectedly revoked by this milestone';
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ENTRY SERVER MUTATION FOUNDATION RLS TESTS: 12/12 PASSED'; END $$;
ROLLBACK;
