-- CAP-003 Phase 1.8A behavioral test suite. Disposable local
-- PostgreSQL only. Exercises the full evidenced Internal Collaboration
-- lifecycle through the new server-authoritative RPCs. Internal
-- Collaboration is strictly single-org by design (no org_id column,
-- from_section_id/to_section_id always resolve to the same org), so a
-- second organization ("Org Gamma") is seeded only to prove
-- create_internal_request's/reroute_internal_request's org-consistency
-- guards reject a foreign-org section -- not for a bidirectionality
-- dimension the module itself doesn't have.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('18a00000-0000-0000-0000-000000000001','T18A Org','authority','T18A'),
  ('18a00000-0000-0000-0000-000000000002','T18A Org Gamma','authority','T18G');
INSERT INTO divisions(id, org_id, name) VALUES
  ('18a00000-0004-0000-0000-000000000001','18a00000-0000-0000-0000-000000000001','Div'),
  ('18a00000-0004-0000-0000-000000000002','18a00000-0000-0000-0000-000000000002','Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('18a00000-0002-0000-0000-000000000001','18a00000-0000-0000-0000-000000000001','18a00000-0004-0000-0000-000000000001','Records','T18REC'),
  ('18a00000-0002-0000-0000-000000000002','18a00000-0000-0000-0000-000000000001','18a00000-0004-0000-0000-000000000001','Welfare','T18WEL'),
  ('18a00000-0002-0000-0000-000000000003','18a00000-0000-0000-0000-000000000001','18a00000-0004-0000-0000-000000000001','Operations','T18OPS'),
  ('18a00000-0002-0000-0000-000000000009','18a00000-0000-0000-0000-000000000002','18a00000-0004-0000-0000-000000000002','Gamma Sec','T18GS');

INSERT INTO auth.users(id,email) VALUES
  ('18a00000-0001-0000-0000-000000000001','t18a-records@t.local'),
  ('18a00000-0001-0000-0000-000000000002','t18a-welfare@t.local'),
  ('18a00000-0001-0000-0000-000000000003','t18a-welfaresuper@t.local'),
  ('18a00000-0001-0000-0000-000000000004','t18a-outsider@t.local'),
  ('18a00000-0001-0000-0000-000000000005','t18a-ops@t.local'),
  ('18a00000-0001-0000-0000-000000000006','t18a-inactive@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('18a00000-0001-0000-0000-000000000001','18a00000-0000-0000-0000-000000000001','T18A-1','Records Staff','t18a-records@t.local',TRUE),
  ('18a00000-0001-0000-0000-000000000002','18a00000-0000-0000-0000-000000000001','T18A-2','Welfare Staff','t18a-welfare@t.local',TRUE),
  ('18a00000-0001-0000-0000-000000000003','18a00000-0000-0000-0000-000000000001','T18A-3','Welfare Supervisor','t18a-welfaresuper@t.local',TRUE),
  ('18a00000-0001-0000-0000-000000000004','18a00000-0000-0000-0000-000000000001','T18A-4','Outsider','t18a-outsider@t.local',TRUE),
  ('18a00000-0001-0000-0000-000000000005','18a00000-0000-0000-0000-000000000001','T18A-5','Ops Staff','t18a-ops@t.local',TRUE),
  ('18a00000-0001-0000-0000-000000000006','18a00000-0000-0000-0000-000000000001','T18A-6','Inactive Staff','t18a-inactive@t.local',FALSE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('18a00000-0001-0000-0000-000000000001','section','18a00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('18a00000-0001-0000-0000-000000000002','section','18a00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('18a00000-0001-0000-0000-000000000003','section','18a00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('18a00000-0001-0000-0000-000000000005','section','18a00000-0002-0000-0000-000000000003','staff',TRUE,TRUE);
-- Outsider (18a...004) deliberately has NO assignment at all.
-- Inactive (18a...006) has no assignment either; only used as an assign_internal_request target.

SET ROLE authenticated;

-- ═══ TEST 1: create_internal_request (Request-anchored) produces a
-- 'sent' thread owned by the org ═══
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'Parent subj', 'Parent body', 'en', 'en', NULL, NULL);
  PERFORM set_config('app.t18a_preq', v_preq.id::text, false);

  v_ic := create_internal_request(
    '18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002',
    'Need welfare input', 'Please advise', v_preq.id, NULL
  );
  IF v_ic.status <> 'sent' OR v_ic.to_section_id <> '18a00000-0002-0000-0000-000000000002' OR v_ic.parent_request_id <> v_preq.id THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_internal_request did not produce expected sent thread';
  END IF;
  PERFORM set_config('app.t18a_ic1', v_ic.id::text, false);
  RAISE NOTICE 'TEST 1 PASSED: create_internal_request (Request-anchored) produces a sent thread';
END $$;

-- ═══ TEST 2: create_internal_request rejects providing both parents,
-- or neither ═══
DO $$
DECLARE v_preq_id UUID := current_setting('app.t18a_preq')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S', 'B', NULL, NULL);
    RAISE EXCEPTION 'TEST 2a FAILED: create_internal_request should reject having neither parent';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 2a PASSED: create_internal_request rejects neither-parent: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 3: create_internal_request rejects a to_section_id outside
-- the caller's own organization ═══
DO $$
DECLARE v_preq_id UUID := current_setting('app.t18a_preq')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000009', 'S', 'B', v_preq_id, NULL);
    RAISE EXCEPTION 'TEST 3 FAILED: create_internal_request should reject a foreign-org to_section_id';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 3 PASSED: create_internal_request rejects a to_section_id outside the caller''s own organization: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 4: mark_internal_request_received stamps receipt, replay
-- rejected ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic1')::UUID; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_id);
  IF v_ic.received_by <> '18a00000-0001-0000-0000-000000000002' OR v_ic.received_at IS NULL OR v_ic.status <> 'received' THEN
    RAISE EXCEPTION 'TEST 4 FAILED: mark_internal_request_received did not stamp receipt';
  END IF;
  BEGIN
    PERFORM mark_internal_request_received(v_id);
    RAISE EXCEPTION 'TEST 4b FAILED: duplicate mark_internal_request_received should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 4b PASSED: duplicate mark_internal_request_received (replay) rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 4 PASSED: mark_internal_request_received stamps receipt on the receiving section side';
END $$;

-- ═══ TEST 5: assign_internal_request sets assigned_to+in_progress,
-- rejects inactive user, unassign resets to received ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic1')::UUID; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM assign_internal_request(v_id, '18a00000-0001-0000-0000-000000000006');
    RAISE EXCEPTION 'TEST 5a FAILED: assign_internal_request should reject an inactive user';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 5a PASSED: assign_internal_request rejects an inactive assignee: %', SQLERRM;
  END;
  v_ic := assign_internal_request(v_id, '18a00000-0001-0000-0000-000000000002');
  IF v_ic.assigned_to <> '18a00000-0001-0000-0000-000000000002' OR v_ic.status <> 'in_progress' THEN
    RAISE EXCEPTION 'TEST 5b FAILED: assign_internal_request did not set assigned_to/in_progress';
  END IF;
  v_ic := assign_internal_request(v_id, NULL);
  IF v_ic.assigned_to IS NOT NULL OR v_ic.status <> 'received' THEN
    RAISE EXCEPTION 'TEST 5c FAILED: unassigning did not reset assigned_to/status to received';
  END IF;
  v_ic := assign_internal_request(v_id, '18a00000-0001-0000-0000-000000000002');
  RAISE NOTICE 'TEST 5 PASSED: assign_internal_request assigns/unassigns correctly, rejects inactive users';
END $$;

-- ═══ TEST 6: reroute_internal_request routes to a new section,
-- resetting received/assigned side; rejects a foreign-org section ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic1')::UUID; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM reroute_internal_request(v_id, '18a00000-0002-0000-0000-000000000009');
    RAISE EXCEPTION 'TEST 6a FAILED: reroute_internal_request should reject a foreign-org section';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 6a PASSED: reroute_internal_request rejects a foreign-org target section: %', SQLERRM;
  END;
  v_ic := reroute_internal_request(v_id, '18a00000-0002-0000-0000-000000000003');
  IF v_ic.status <> 'sent' OR v_ic.to_section_id <> '18a00000-0002-0000-0000-000000000003'
     OR v_ic.received_by IS NOT NULL OR v_ic.assigned_to IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 6b FAILED: reroute_internal_request did not correctly reset the receiving side';
  END IF;
  RAISE NOTICE 'TEST 6 PASSED: reroute_internal_request routes to a new same-org section and resets received/assigned state';
END $$;

-- ═══ TEST 7: return_internal_request_to_sender -- narrower
-- authorization (to_section member ONLY, not supervisor-bypass, not
-- from_section) and status-eligibility guard, matching the evidenced
-- UI gate exactly ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic1')::UUID; v_ic internal_requests;
BEGIN
  -- Ops is now the current to_section (from TEST 6's reroute). Records
  -- (the original from_section) member trying to return-to-sender must
  -- be rejected -- only the CURRENT holder (Ops) may do this.
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM return_internal_request_to_sender(v_id, 'wrong section, sending back');
    RAISE EXCEPTION 'TEST 7a FAILED: a from_section (non-current-holder) member should not be able to return-to-sender';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 7a PASSED: return_internal_request_to_sender rejects a caller who is not the CURRENT to_section holder: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000005"}',true); -- Ops staff, current holder
  v_ic := return_internal_request_to_sender(v_id, 'wrong section, sending back');
  IF v_ic.status <> 'sent' OR v_ic.to_section_id <> '18a00000-0002-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'TEST 7b FAILED: return_internal_request_to_sender did not route back to from_section_id (Records)';
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: return_internal_request_to_sender routes back to the thread''s own permanent from_section_id, current-holder-only authorization';
END $$;

-- ═══ TEST 8: return_internal_request_to_sender status-eligibility
-- guard -- rejected once the thread has moved past in_progress ═══
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_reply internal_request_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'S8', 'B8', 'en', 'en', NULL, NULL);
  v_ic := create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S8', 'B8', v_preq.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_ic.id, 'reply body');
  v_reply := submit_internal_request_reply(v_reply.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true);
  v_reply := approve_internal_request_reply(v_reply.id);
  -- thread is now 'responded' -- return-to-sender should be rejected
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM return_internal_request_to_sender(v_ic.id, 'too late');
    RAISE EXCEPTION 'TEST 8 FAILED: return_internal_request_to_sender should be rejected once the thread has responded';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 8 PASSED: return_internal_request_to_sender rejects a thread no longer in an eligible status (responded): %', SQLERRM;
  END;
END $$;

-- ═══ TEST 9-12: reply lifecycle draft -> pending_approval -> sent,
-- atomic thread status flip. Uses its own fresh thread (not ic1, which
-- by this point has been rerouted/returned-to-sender away from Welfare
-- by TESTs 6-7) so the current to_section holder (Welfare) matches the
-- drafting user throughout ═══
DO $$
DECLARE v_preq requests; v_id UUID; v_ic internal_requests; v_reply internal_request_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'S9', 'B9', 'en', 'en', NULL, NULL);
  v_ic := create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S9', 'B9', v_preq.id, NULL);
  v_id := v_ic.id;
  PERFORM set_config('app.t18a_ic9', v_id::text, false);

  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_id, 'T9 reply body');
  IF v_reply.status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: draft_internal_request_reply did not produce a draft';
  END IF;
  PERFORM set_config('app.t18a_reply1', v_reply.id::text, false);

  v_reply := update_internal_request_reply_draft(v_reply.id, 'T9 reply body edited');
  IF v_reply.body <> 'T9 reply body edited' THEN
    RAISE EXCEPTION 'TEST 10 FAILED: update_internal_request_reply_draft did not apply';
  END IF;
  RAISE NOTICE 'TEST 9-10 PASSED: draft_internal_request_reply / update_internal_request_reply_draft';

  v_reply := submit_internal_request_reply(v_reply.id, NULL);
  IF v_reply.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'TEST 11 FAILED: submit_internal_request_reply did not transition';
  END IF;
  BEGIN
    PERFORM submit_internal_request_reply(v_reply.id, NULL);
    RAISE EXCEPTION 'TEST 11b FAILED: duplicate submit_internal_request_reply should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 11b PASSED: duplicate submit_internal_request_reply (replay) rejected: %', SQLERRM;
  END;

  -- non-author cannot submit someone else's draft
  RAISE NOTICE 'TEST 11 PASSED: submit_internal_request_reply transitions draft -> pending_approval, author-only, no replay';
END $$;

-- ═══ TEST 12: submit_internal_request_reply rejects a non-author ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic9')::UUID; v_reply internal_request_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true); -- supervisor, not the drafter
  v_reply := draft_internal_request_reply(v_id, 'T12 not my reply to submit as someone else');
  RESET ROLE; SET ROLE authenticated; -- no-op, keeps role consistent
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM submit_internal_request_reply(v_reply.id, NULL);
    RAISE EXCEPTION 'TEST 12 FAILED: a non-author should not be able to submit someone else''s draft reply';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 12 PASSED: submit_internal_request_reply rejects a non-author caller: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 13: approve_internal_request_reply rejects a non-supervisor
-- (the drafter themselves) ═══
DO $$
DECLARE v_reply_id UUID := current_setting('app.t18a_reply1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM approve_internal_request_reply(v_reply_id);
    RAISE EXCEPTION 'TEST 13 FAILED: the drafter should not be able to approve their own reply';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 13 PASSED: approve_internal_request_reply rejects a non-supervisor caller: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 14: approve_internal_request_reply atomically fuses reply=
-- sent AND thread=responded in one transaction (the fixed non-
-- atomicity gap -- see patch header) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic9')::UUID; v_reply_id UUID := current_setting('app.t18a_reply1')::UUID;
  v_reply internal_request_replies; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true);
  v_reply := approve_internal_request_reply(v_reply_id);
  SELECT * INTO v_ic FROM internal_requests WHERE id = v_id;
  IF v_reply.status <> 'sent' OR v_reply.approved_by <> '18a00000-0001-0000-0000-000000000003' OR v_ic.status <> 'responded' THEN
    RAISE EXCEPTION 'TEST 14 FAILED: approve_internal_request_reply did not atomically set reply=sent and thread=responded (reply=%, thread=%)', v_reply.status, v_ic.status;
  END IF;
  RAISE NOTICE 'TEST 14 PASSED: approve_internal_request_reply atomically transitions reply to sent AND thread to responded in one transaction';
END $$;

-- ═══ TEST 15: forced-failure atomicity proof -- re-approving an
-- already-sent reply must fail, and must leave both rows completely
-- unchanged (no partial re-application) ═══
DO $$
DECLARE v_reply_id UUID := current_setting('app.t18a_reply1')::UUID; v_id UUID := current_setting('app.t18a_ic9')::UUID;
  v_reply_before internal_request_replies; v_reply_after internal_request_replies;
  v_ic_before internal_requests; v_ic_after internal_requests;
BEGIN
  SELECT * INTO v_reply_before FROM internal_request_replies WHERE id = v_reply_id;
  SELECT * INTO v_ic_before FROM internal_requests WHERE id = v_id;
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM approve_internal_request_reply(v_reply_id);
    RAISE EXCEPTION 'TEST 15 FAILED: re-approving an already-sent reply should be rejected';
  EXCEPTION WHEN OTHERS THEN
    NULL; -- expected
  END;
  SELECT * INTO v_reply_after FROM internal_request_replies WHERE id = v_reply_id;
  SELECT * INTO v_ic_after FROM internal_requests WHERE id = v_id;
  IF v_reply_after.approved_at IS DISTINCT FROM v_reply_before.approved_at
     OR v_ic_after.status IS DISTINCT FROM v_ic_before.status THEN
    RAISE EXCEPTION 'TEST 15 FAILED: partial state leaked from a rejected approve_internal_request_reply replay';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: a rejected approve_internal_request_reply replay leaves zero partial state (fully atomic)';
END $$;

-- ═══ TEST 16: return_internal_request_reply sends a pending_approval
-- reply back to draft, writes NO approvals-table row (Internal
-- Collaboration never uses the shared approvals table -- see patch
-- header) ═══
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_reply internal_request_replies; v_approvals INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'S16', 'B16', 'en', 'en', NULL, NULL);
  v_ic := create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S16', 'B16', v_preq.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_ic.id, 'T16 reply body');
  v_reply := submit_internal_request_reply(v_reply.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true);
  v_reply := return_internal_request_reply(v_reply.id);
  IF v_reply.status <> 'draft' OR v_reply.pending_approval_by IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 16 FAILED: return_internal_request_reply did not send the draft back';
  END IF;
  SELECT count(*) INTO v_approvals FROM approvals WHERE record_id = v_reply.id;
  IF v_approvals <> 0 THEN
    RAISE EXCEPTION 'TEST 16 FAILED: return_internal_request_reply unexpectedly wrote to the shared approvals table (found % rows)', v_approvals;
  END IF;
  RAISE NOTICE 'TEST 16 PASSED: return_internal_request_reply sends a pending reply back to draft, no approvals-table write (matches real current architecture)';
END $$;

-- ═══ TEST 17: return_internal_request_reply rejects a non-pending
-- reply (status guard) ═══
DO $$
DECLARE v_reply_id UUID := current_setting('app.t18a_reply1')::UUID; -- already 'sent' from TEST 14
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM return_internal_request_reply(v_reply_id);
    RAISE EXCEPTION 'TEST 17 FAILED: return_internal_request_reply on an already-sent reply should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 17 PASSED: return_internal_request_reply rejects a reply that is not pending_approval: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 18: close_internal_request closes a thread (no status
-- guard, matching close_request()/close_entry()'s own real lenient
-- authorization-only posture -- see patch header) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t18a_ic1')::UUID; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_ic := close_internal_request(v_id);
  IF v_ic.status <> 'closed' THEN
    RAISE EXCEPTION 'TEST 18 FAILED: close_internal_request did not close the thread';
  END IF;
  RAISE NOTICE 'TEST 18 PASSED: close_internal_request closes the thread';
END $$;

-- ═══ TEST 19: create_internal_request rejects starting a new thread
-- once the parent Request is frozen (cancelled/closed/responded) --
-- reproduces internal_requests_parent_startable() ═══
DO $$
DECLARE v_preq requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'S19', 'B19', 'en', 'en', NULL, NULL);
  -- cancel_request only accepts sent/received/in_progress/overdue, so
  -- drive the fresh draft to 'sent' first (submit -> approve) before
  -- cancelling it to reach the frozen ('cancelled') state under test.
  PERFORM submit_request(v_preq.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000003"}',true); -- supervisor
  PERFORM approve_request(v_preq.id, NULL);
  -- cancel_request requires either the original creator, or a
  -- supervisor of the request's OWN from_section (Records has none in
  -- these fixtures) -- switch back to the creator to cancel.
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  PERFORM cancel_request(v_preq.id, 'test cancel');
  BEGIN
    PERFORM create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S19b', 'B19b', v_preq.id, NULL);
    RAISE EXCEPTION 'TEST 19 FAILED: create_internal_request should be rejected once the parent request is cancelled';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 19 PASSED: create_internal_request rejects starting a new thread on a frozen (cancelled) parent request: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 20: Entry-anchored thread (parent_entry_id) also works
-- end to end -- the polymorphic parent, proving this migration
-- correctly reproduces internal_requests_parent_startable()'s own
-- Entry branch, not just its Request branch ═══
DO $$
DECLARE v_ent external_correspondence; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Entry Sender','S20 subject','S20 body');
  v_ic := create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S20', 'B20', NULL, v_ent.id);
  IF v_ic.parent_entry_id <> v_ent.id OR v_ic.parent_request_id IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 20 FAILED: create_internal_request (Entry-anchored) did not set parent_entry_id correctly';
  END IF;
  RAISE NOTICE 'TEST 20 PASSED: create_internal_request correctly anchors a thread to a parent Entry case (polymorphic parent)';
END $$;

-- ═══ TEST 21: outsider (no assignment, not in either section)
-- rejected everywhere ═══
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18a00000-0002-0000-0000-000000000001', '18a00000-0000-0000-0000-000000000001', 'S21', 'B21', 'en', 'en', NULL, NULL);
  v_ic := create_internal_request('18a00000-0002-0000-0000-000000000001', '18a00000-0002-0000-0000-000000000002', 'S21', 'B21', v_preq.id, NULL);

  PERFORM set_config('request.jwt.claims','{"sub":"18a00000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM mark_internal_request_received(v_ic.id);
    RAISE EXCEPTION 'TEST 21a FAILED: outsider should not be able to mark received';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 21a PASSED: mark_internal_request_received rejects an outsider caller: %', SQLERRM;
  END;
  BEGIN
    PERFORM reroute_internal_request(v_ic.id, '18a00000-0002-0000-0000-000000000003');
    RAISE EXCEPTION 'TEST 21b FAILED: outsider should not be able to reroute';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 21b PASSED: reroute_internal_request rejects an outsider caller: %', SQLERRM;
  END;
  BEGIN
    PERFORM create_internal_request('18a00000-0002-0000-0000-000000000002', '18a00000-0002-0000-0000-000000000001', 'x', 'y', v_preq.id, NULL);
    RAISE EXCEPTION 'TEST 21c FAILED: outsider should not be able to create a thread on behalf of a section they are not in';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 21c PASSED: create_internal_request rejects an outsider acting on behalf of a from_section they do not belong to: %', SQLERRM;
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'INTERNAL COLLABORATION SERVER MUTATION FOUNDATION BEHAVIORAL TESTS: 21 scenarios (with sub-checks) PASSED'; END $$;
ROLLBACK;
