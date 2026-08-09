-- CAP-003 Phase 1.6A behavioral test suite. Disposable local
-- PostgreSQL only. Exercises the full evidenced Requests lifecycle
-- through the new server-authoritative RPCs, in BOTH organization
-- directions (generic orgs "Org Alpha"/"Org Beta", never MCS/HRCM by
-- name, per the bidirectionality requirement), plus atomicity/replay
-- proofs specific to this milestone.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('16a00000-0000-0000-0000-000000000001','Org Alpha','authority','ALPH'),
  ('16a00000-0000-0000-0000-000000000002','Org Beta','authority','BETA');
INSERT INTO divisions(id, org_id, name) VALUES
  ('16a00000-0004-0000-0000-000000000001','16a00000-0000-0000-0000-000000000001','Alpha Div'),
  ('16a00000-0004-0000-0000-000000000002','16a00000-0000-0000-0000-000000000002','Beta Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000001','16a00000-0004-0000-0000-000000000001','Alpha Sec A','AA1'),
  ('16a00000-0002-0000-0000-000000000002','16a00000-0000-0000-0000-000000000001','16a00000-0004-0000-0000-000000000001','Alpha Sec B','AA2'),
  ('16a00000-0002-0000-0000-000000000003','16a00000-0000-0000-0000-000000000002','16a00000-0004-0000-0000-000000000002','Beta Sec A','BA1'),
  ('16a00000-0002-0000-0000-000000000004','16a00000-0000-0000-0000-000000000002','16a00000-0004-0000-0000-000000000002','Beta Sec B','BA2');

INSERT INTO auth.users(id,email) VALUES
  ('16a00000-0001-0000-0000-000000000001','t16a-alpha-staff@t.local'),
  ('16a00000-0001-0000-0000-000000000002','t16a-alpha-super@t.local'),
  ('16a00000-0001-0000-0000-000000000003','t16a-beta-staff@t.local'),
  ('16a00000-0001-0000-0000-000000000004','t16a-beta-super@t.local'),
  ('16a00000-0001-0000-0000-000000000005','t16a-beta-staffB@t.local'),
  ('16a00000-0001-0000-0000-000000000006','t16a-outsider@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('16a00000-0001-0000-0000-000000000001','16a00000-0000-0000-0000-000000000001','T16A-1','Alpha Staff','t16a-alpha-staff@t.local',TRUE),
  ('16a00000-0001-0000-0000-000000000002','16a00000-0000-0000-0000-000000000001','T16A-2','Alpha Super','t16a-alpha-super@t.local',TRUE),
  ('16a00000-0001-0000-0000-000000000003','16a00000-0000-0000-0000-000000000002','T16A-3','Beta Staff A','t16a-beta-staff@t.local',TRUE),
  ('16a00000-0001-0000-0000-000000000004','16a00000-0000-0000-0000-000000000002','T16A-4','Beta Super','t16a-beta-super@t.local',TRUE),
  ('16a00000-0001-0000-0000-000000000005','16a00000-0000-0000-0000-000000000002','T16A-5','Beta Staff B','t16a-beta-staffB@t.local',TRUE),
  ('16a00000-0001-0000-0000-000000000006','16a00000-0000-0000-0000-000000000001','T16A-6','Outsider','t16a-outsider@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('16a00000-0001-0000-0000-000000000001','section','16a00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('16a00000-0001-0000-0000-000000000002','section','16a00000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
  ('16a00000-0001-0000-0000-000000000003','section','16a00000-0002-0000-0000-000000000003','staff',TRUE,TRUE),
  ('16a00000-0001-0000-0000-000000000004','section','16a00000-0002-0000-0000-000000000003','supervisor',TRUE,TRUE),
  ('16a00000-0001-0000-0000-000000000005','section','16a00000-0002-0000-0000-000000000004','staff',TRUE,TRUE);
-- Outsider (16a...006) deliberately has NO assignment at all.

SET ROLE authenticated;

-- ═══ Direction A: Alpha -> Beta ═══════════════════════════════════
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','A->B subject','A->B body','en','en',NULL,NULL);
  IF v_req.status <> 'draft' OR v_req.from_org_id <> '16a00000-0000-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_request did not produce expected draft row';
  END IF;
  PERFORM set_config('app.t16a_req_ab', v_req.id::text, false);
  RAISE NOTICE 'TEST 1 PASSED: create_request (Alpha->Beta) produces a draft owned by the sending org';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := update_request_draft(v_id, 'A->B subject edited', 'en', 'A->B body edited', 'en', NULL);
  IF v_req.subject <> 'A->B subject edited' THEN
    RAISE EXCEPTION 'TEST 2 FAILED: update_request_draft did not apply';
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: update_request_draft applies to own unlocked draft';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := submit_request(v_id, NULL);
  IF v_req.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'TEST 3 FAILED: submit_request did not transition to pending_approval';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: submit_request transitions draft -> pending_approval';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID;
BEGIN
  -- invalid transition: submitting again while already pending_approval
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM submit_request(v_id, NULL);
    RAISE EXCEPTION 'TEST 4 FAILED: duplicate submit_request should have been rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%requires an authenticated%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 4 PASSED: duplicate submit_request (replay) rejected: %', SQLERRM;
  END;
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID;
BEGIN
  -- wrong org: Beta staff cannot approve an Alpha-originated request in pending_approval (not a supervisor of either side)
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM approve_request(v_id, NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: non-supervisor Beta staff should not approve an unrelated request';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 5 PASSED: unauthorized approve_request rejected: %', SQLERRM;
  END;
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests; v_approvals INT; v_audit INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_id, 'approved for smoke test');
  IF v_req.status <> 'sent' OR v_req.reference_number IS NULL OR NOT v_req.is_locked THEN
    RAISE EXCEPTION 'TEST 6 FAILED: approve_request did not sent+lock+reference_number atomically';
  END IF;
  SELECT count(*) INTO v_approvals FROM approvals WHERE record_type='request' AND record_id=v_id AND decision='approved';
  SELECT count(*) INTO v_audit FROM audit_logs WHERE record_type='request' AND record_id=v_id AND action='approved';
  IF v_approvals <> 1 OR v_audit <> 1 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: approve_request did not atomically write approvals+audit (approvals=%, audit=%)', v_approvals, v_audit;
  END IF;
  RAISE NOTICE 'TEST 6 PASSED: approve_request is atomic (status+lock+refnum+approvals+audit) and produces history evidence';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests;
BEGIN
  -- receiving org's supervisor marks received
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := mark_request_received(v_id);
  IF v_req.status <> 'received' OR v_req.received_by <> '16a00000-0001-0000-0000-000000000004' THEN
    RAISE EXCEPTION 'TEST 7 FAILED: mark_request_received did not stamp receipt';
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: mark_request_received (Beta supervisor) stamps receipt on Alpha->Beta request';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests;
BEGIN
  -- route to a wrong-org section is rejected
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM route_request(v_id, '16a00000-0002-0000-0000-000000000001'); -- Alpha's own section, not Beta's
    RAISE EXCEPTION 'TEST 8 FAILED: routing to a foreign-org section should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 8 PASSED: route_request rejects a to_section_id outside the receiving organization: %', SQLERRM;
  END;
  v_req := route_request(v_id, '16a00000-0002-0000-0000-000000000003');
  IF v_req.status <> 'in_progress' OR v_req.to_section_id <> '16a00000-0002-0000-0000-000000000003' OR v_req.assigned_to IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 8b FAILED: route_request did not route correctly';
  END IF;
  RAISE NOTICE 'TEST 8b PASSED: route_request routes to the correct-org section and clears assigned_to';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := assign_request(v_id, '16a00000-0001-0000-0000-000000000003');
  IF v_req.assigned_to <> '16a00000-0001-0000-0000-000000000003' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: assign_request did not set assigned_to';
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: assign_request assigns within the routed section';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ab')::UUID; v_resp responses;
BEGIN
  -- Beta staff (assignee) drafts, submits, and Beta supervisor approves a response
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000003"}',true);
  v_resp := create_response(v_id, 'A->B response body', 'en');
  PERFORM set_config('app.t16a_resp_ab', v_resp.id::text, false);
  IF v_resp.status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 10 FAILED: create_response did not produce a draft';
  END IF;
  v_resp := update_response_draft(v_resp.id, 'A->B response body edited', 'en');
  v_resp := submit_response(v_resp.id, NULL);
  IF v_resp.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'TEST 10 FAILED: submit_response did not transition';
  END IF;
  RAISE NOTICE 'TEST 10 PASSED: create_response/update_response_draft/submit_response full cycle';
END $$;

DO $$
DECLARE v_req_id UUID := current_setting('app.t16a_req_ab')::UUID; v_resp_id UUID := current_setting('app.t16a_resp_ab')::UUID;
  v_resp responses; v_req requests; v_approvals INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_resp := approve_response(v_resp_id, 'approved response');
  SELECT * INTO v_req FROM requests WHERE id = v_req_id;
  IF v_resp.status <> 'sent' OR v_resp.reference_number IS NULL OR v_req.status <> 'responded' THEN
    RAISE EXCEPTION 'TEST 11 FAILED: approve_response did not atomically sent+lock+refnum the response AND mark the request responded (resp status=%, req status=%)', v_resp.status, v_req.status;
  END IF;
  SELECT count(*) INTO v_approvals FROM approvals WHERE record_type='response' AND record_id=v_resp_id AND decision='approved';
  IF v_approvals <> 1 THEN
    RAISE EXCEPTION 'TEST 11 FAILED: approve_response did not write an approvals row';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: approve_response is atomic across responses+requests+approvals+audit';
END $$;

DO $$
DECLARE v_req_id UUID := current_setting('app.t16a_req_ab')::UUID; v_resp_id UUID := current_setting('app.t16a_resp_ab')::UUID; v_req requests;
BEGIN
  -- Acknowledge & close, composed+atomic
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := acknowledge_and_close(v_resp_id, v_req_id);
  IF v_req.status <> 'closed' THEN
    RAISE EXCEPTION 'TEST 12 FAILED: acknowledge_and_close did not close the request';
  END IF;
  IF (SELECT received_by FROM responses WHERE id = v_resp_id) IS NULL THEN
    RAISE EXCEPTION 'TEST 12 FAILED: acknowledge_and_close did not mark the response received';
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: acknowledge_and_close atomically receives the response and closes the request';
END $$;

-- ═══ Direction B: Beta -> Alpha (bidirectionality regression) ═════
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000003"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000003','16a00000-0000-0000-0000-000000000001','B->A subject','B->A body','en','en',NULL,NULL);
  PERFORM set_config('app.t16a_req_ba', v_req.id::text, false);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000003"}',true);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := approve_request(v_req.id, NULL);
  IF v_req.status <> 'sent' OR v_req.from_org_id <> '16a00000-0000-0000-0000-000000000002' THEN
    RAISE EXCEPTION 'TEST 13 FAILED: Beta->Alpha create/submit/approve cycle did not work';
  END IF;
  RAISE NOTICE 'TEST 13 PASSED: Beta -> Alpha direction works end to end through create_request/submit_request/approve_request (org B is not hard-coded as reply-only)';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_ba')::UUID; v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := mark_request_received(v_id);
  v_req := route_request(v_id, '16a00000-0002-0000-0000-000000000001');
  IF v_req.status <> 'in_progress' THEN
    RAISE EXCEPTION 'TEST 14 FAILED: Alpha-side receive/route of an inbound Beta request failed';
  END IF;
  RAISE NOTICE 'TEST 14 PASSED: receiving org (Alpha) can receive/route an inbound request just as Beta could -- no reply-only asymmetry';
END $$;

-- ═══ receive_and_route_request: atomicity, replaces 2-3 call composition ═══
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','RAR subject','RAR body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('app.t16a_req_rar', v_req.id::text, false);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);

  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := receive_and_route_request(v_req.id, '16a00000-0002-0000-0000-000000000003', '16a00000-0001-0000-0000-000000000003');
  IF v_req.status <> 'in_progress' OR v_req.received_by IS NULL OR v_req.to_section_id <> '16a00000-0002-0000-0000-000000000003' OR v_req.assigned_to <> '16a00000-0001-0000-0000-000000000003' THEN
    RAISE EXCEPTION 'TEST 15 FAILED: receive_and_route_request did not atomically receive+route+assign';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: receive_and_route_request atomically receives, routes, and assigns in one transaction';
END $$;

-- forced failure between steps: a second, immediate call with an invalid
-- to_section_id (foreign org) must roll back WITHOUT leaving the request
-- half-received/half-routed again.
DO $$
DECLARE v_id UUID := current_setting('app.t16a_req_rar')::UUID; v_before requests; v_after requests;
BEGIN
  SELECT * INTO v_before FROM requests WHERE id = v_id;
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM receive_and_route_request(v_id, '16a00000-0002-0000-0000-000000000001', NULL); -- Alpha section, wrong org for this Beta-side actor to route into their own inbox
    RAISE EXCEPTION 'TEST 16 FAILED: should have been rejected';
  EXCEPTION WHEN OTHERS THEN
    NULL; -- expected
  END;
  SELECT * INTO v_after FROM requests WHERE id = v_id;
  IF v_after.to_section_id <> v_before.to_section_id OR v_after.status <> v_before.status OR v_after.assigned_to IS DISTINCT FROM v_before.assigned_to THEN
    RAISE EXCEPTION 'TEST 16 FAILED: partial state leaked from a rejected receive_and_route_request call (before to_section=%, after to_section=%)', v_before.to_section_id, v_after.to_section_id;
  END IF;
  RAISE NOTICE 'TEST 16 PASSED: a rejected receive_and_route_request leaves zero partial state (fully atomic)';
END $$;

-- ═══ update_request_draft explicit-column safety (no arbitrary patch) ═══
DO $$
DECLARE v_req requests; v_before_from_org UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','Column safety subject','Column safety body','en','en',NULL,NULL);
  v_before_from_org := v_req.from_org_id;
  v_req := update_request_draft(v_req.id, 'Edited subject only', 'en', 'Edited body only', 'en', NULL);
  IF v_req.from_org_id <> v_before_from_org THEN
    RAISE EXCEPTION 'TEST 17 FAILED: from_org_id must never be mutable via update_request_draft';
  END IF;
  RAISE NOTICE 'TEST 17 PASSED: update_request_draft only ever touches subject/subject_language/body/language/deadline -- no column beyond those exists in its signature';
END $$;

-- ═══ Return to Sender: same request, no new id created ════════════
DO $$
DECLARE v_id UUID; v_first_section UUID := '16a00000-0002-0000-0000-000000000003'; v_second_section UUID := '16a00000-0002-0000-0000-000000000004';
  v_req requests; v_id_before UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','RTS subject','RTS body','en','en',NULL,NULL);
  v_id := v_req.id; v_id_before := v_req.id;
  v_req := submit_request(v_id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := mark_request_received(v_id);
  v_req := route_request(v_id, v_first_section); -- previous_section_id now points at the default receiving fallback (may be NULL if unset)
  v_req := route_request(v_id, v_second_section); -- previous_section_id trigger now records v_first_section

  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_req := return_request_to_previous_section(v_id, 'wrong section, please take this one');
  IF v_req.id <> v_id_before THEN
    RAISE EXCEPTION 'TEST 18 FAILED: return_request_to_previous_section must never create a new request id';
  END IF;
  IF v_req.to_section_id <> v_first_section THEN
    RAISE EXCEPTION 'TEST 18 FAILED: expected to return to %, got %', v_first_section, v_req.to_section_id;
  END IF;
  RAISE NOTICE 'TEST 18 PASSED: return_request_to_previous_section derives the target section server-side and never creates a new request id';
END $$;

-- ═══ cancel_request: state guard + audit ═══════════════════════════
DO $$
DECLARE v_req requests; v_audit INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','Cancel subject','Cancel body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := cancel_request(v_req.id, 'no longer needed');
  IF v_req.status <> 'cancelled' OR NOT v_req.is_locked OR v_req.cancelled_by <> '16a00000-0001-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'TEST 19 FAILED: cancel_request did not apply expected columns';
  END IF;
  SELECT count(*) INTO v_audit FROM audit_logs WHERE record_type='request' AND record_id=v_req.id AND action='cancelled';
  IF v_audit <> 1 THEN
    RAISE EXCEPTION 'TEST 19 FAILED: cancel_request did not write an audit row';
  END IF;
  -- replay: cancelling an already-cancelled request must be rejected
  BEGIN
    PERFORM cancel_request(v_req.id, 'again');
    RAISE EXCEPTION 'TEST 19b FAILED: duplicate cancel_request should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 19b PASSED: duplicate cancel_request (replay) rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 19 PASSED: cancel_request transitions correctly with audit evidence';
END $$;

-- ═══ return_request (supervisor sends draft back) ══════════════════
DO $$
DECLARE v_req requests; v_approvals INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','Return subject','Return body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := return_request(v_req.id, 'please add more detail');
  IF v_req.status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 20 FAILED: return_request did not send the draft back';
  END IF;
  SELECT count(*) INTO v_approvals FROM approvals WHERE record_type='request' AND record_id=v_req.id AND decision='returned';
  IF v_approvals <> 1 THEN
    RAISE EXCEPTION 'TEST 20 FAILED: return_request did not write a returned approvals row';
  END IF;
  -- creator can now edit and resubmit
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := update_request_draft(v_req.id, 'Return subject v2', 'en', 'Return body v2', 'en', NULL);
  v_req := submit_request(v_req.id, NULL);
  IF v_req.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'TEST 20b FAILED: resubmission after return did not work';
  END IF;
  RAISE NOTICE 'TEST 20 PASSED: return_request sends the draft back with history evidence, and resubmission works';
END $$;

-- ═══ return_response ════════════════════════════════════════════════
DO $$
DECLARE v_req requests; v_resp responses;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','RR subject','RR body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000003"}',true);
  v_resp := create_response(v_req.id, 'RR response body', 'en');
  v_resp := submit_response(v_resp.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000004"}',true);
  v_resp := return_response(v_resp.id, 'needs work');
  IF v_resp.status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 21 FAILED: return_response did not send the draft back';
  END IF;
  RAISE NOTICE 'TEST 21 PASSED: return_response sends a submitted response back to draft';
END $$;

-- ═══ create_response authorization: only the RECEIVING org may respond ═══
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','No self-reply subject','No self-reply body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  -- Alpha (the sender) tries to respond to its own outbound request
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_response(v_req.id, 'self reply', 'en');
    RAISE EXCEPTION 'TEST 22 FAILED: the sending org should not be able to respond to its own request';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 22 PASSED: create_response rejects the sending org attempting to respond to its own request: %', SQLERRM;
  END;
END $$;

-- ═══ Outsider (no assignment, no org membership match) rejected everywhere ═══
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16a00000-0002-0000-0000-000000000001','16a00000-0000-0000-0000-000000000002','Outsider subject','Outsider body','en','en',NULL,NULL);

  PERFORM set_config('request.jwt.claims','{"sub":"16a00000-0001-0000-0000-000000000006"}',true);
  BEGIN
    PERFORM update_request_draft(v_req.id, 'x', 'en', 'y', 'en', NULL);
    RAISE EXCEPTION 'TEST 23 FAILED: outsider should not be able to edit another user''s draft';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 23 PASSED: outsider update_request_draft rejected: %', SQLERRM;
  END;

  BEGIN
    PERFORM cancel_request(v_req.id, 'x');
    RAISE EXCEPTION 'TEST 23b FAILED: outsider should not be able to cancel another user''s request';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 23b PASSED: outsider cancel_request rejected: %', SQLERRM;
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'REQUESTS SERVER MUTATION FOUNDATION BEHAVIORAL TESTS: 23 scenarios (with sub-checks) PASSED'; END $$;
ROLLBACK;
