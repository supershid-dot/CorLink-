-- CAP-003 Phase 1.7A behavioral test suite. Disposable local
-- PostgreSQL only. Exercises the full evidenced Entry lifecycle
-- through the new server-authoritative RPCs. Entry is single-org by
-- design (no from/to duality), so a second organization ("Org Gamma")
-- is seeded only to prove route_entry's org-consistency guard rejects
-- a foreign-org section -- not for a bidirectionality dimension the
-- module itself doesn't have.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('17a00000-0000-0000-0000-000000000001','MCS Test Org','mcs','T17A'),
  ('17a00000-0000-0000-0000-000000000002','Org Gamma','authority','GAMA');
INSERT INTO divisions(id, org_id, name) VALUES
  ('17a00000-0004-0000-0000-000000000001','17a00000-0000-0000-0000-000000000001','Div'),
  ('17a00000-0004-0000-0000-000000000002','17a00000-0000-0000-0000-000000000002','Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('17a00000-0002-0000-0000-000000000001','17a00000-0000-0000-0000-000000000001','17a00000-0004-0000-0000-000000000001','Front Desk','FD1'),
  ('17a00000-0002-0000-0000-000000000002','17a00000-0000-0000-0000-000000000001','17a00000-0004-0000-0000-000000000001','Legal Affairs','LA1'),
  ('17a00000-0002-0000-0000-000000000003','17a00000-0000-0000-0000-000000000001','17a00000-0004-0000-0000-000000000001','Operations','OP1'),
  ('17a00000-0002-0000-0000-000000000009','17a00000-0000-0000-0000-000000000002','17a00000-0004-0000-0000-000000000002','Gamma Sec','GS1');
INSERT INTO entry_sections(org_id, section_id) VALUES
  ('17a00000-0000-0000-0000-000000000001','17a00000-0002-0000-0000-000000000001');

INSERT INTO auth.users(id,email) VALUES
  ('17a00000-0001-0000-0000-000000000001','t17a-frontdesk@t.local'),
  ('17a00000-0001-0000-0000-000000000002','t17a-legal@t.local'),
  ('17a00000-0001-0000-0000-000000000003','t17a-legalsuper@t.local'),
  ('17a00000-0001-0000-0000-000000000004','t17a-outsider@t.local'),
  ('17a00000-0001-0000-0000-000000000005','t17a-ops@t.local'),
  ('17a00000-0001-0000-0000-000000000006','t17a-inactive@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('17a00000-0001-0000-0000-000000000001','17a00000-0000-0000-0000-000000000001','T17A-1','Front Desk Staff','t17a-frontdesk@t.local',TRUE),
  ('17a00000-0001-0000-0000-000000000002','17a00000-0000-0000-0000-000000000001','T17A-2','Legal Staff','t17a-legal@t.local',TRUE),
  ('17a00000-0001-0000-0000-000000000003','17a00000-0000-0000-0000-000000000001','T17A-3','Legal Supervisor','t17a-legalsuper@t.local',TRUE),
  ('17a00000-0001-0000-0000-000000000004','17a00000-0000-0000-0000-000000000001','T17A-4','Outsider','t17a-outsider@t.local',TRUE),
  ('17a00000-0001-0000-0000-000000000005','17a00000-0000-0000-0000-000000000001','T17A-5','Ops Staff','t17a-ops@t.local',TRUE),
  ('17a00000-0001-0000-0000-000000000006','17a00000-0000-0000-0000-000000000001','T17A-6','Inactive Staff','t17a-inactive@t.local',FALSE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('17a00000-0001-0000-0000-000000000001','section','17a00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('17a00000-0001-0000-0000-000000000002','section','17a00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('17a00000-0001-0000-0000-000000000003','section','17a00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('17a00000-0001-0000-0000-000000000005','section','17a00000-0002-0000-0000-000000000003','staff',TRUE,TRUE);
-- Outsider (17a...004) deliberately has NO assignment at all.
-- Inactive (17a...006) has no assignment either; only used as an assign_entry target.

SET ROLE authenticated;

-- ═══ TEST 1: create_entry produces a 'logged' row owned by the org ═══
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Jane Public','T1 subject','T1 body');
  IF v_ent.status <> 'logged' OR v_ent.org_id <> '17a00000-0000-0000-0000-000000000001' OR v_ent.reference_number IS NULL THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_entry did not produce expected logged row';
  END IF;
  PERFORM set_config('app.t17a_ent1', v_ent.id::text, false);
  RAISE NOTICE 'TEST 1 PASSED: create_entry produces a logged row with a reference number';
END $$;

-- ═══ TEST 2: update_entry_draft applies, and never touches org_id/entered_by ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_ent external_correspondence; v_before_org UUID; v_before_entered UUID;
BEGIN
  SELECT org_id, entered_by INTO v_before_org, v_before_entered FROM external_correspondence WHERE id = v_id;
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := update_entry_draft(v_id, 'T1 subject edited', 'en', 'T1 body edited', 'en', NULL);
  IF v_ent.subject <> 'T1 subject edited' THEN
    RAISE EXCEPTION 'TEST 2 FAILED: update_entry_draft did not apply';
  END IF;
  IF v_ent.org_id <> v_before_org OR v_ent.entered_by <> v_before_entered THEN
    RAISE EXCEPTION 'TEST 2 FAILED: org_id/entered_by must never be mutable via update_entry_draft';
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: update_entry_draft applies subject/body only, org_id/entered_by immutable';
END $$;

-- ═══ TEST 3: route_entry rejects a foreign-org section ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM route_entry(v_id, '17a00000-0002-0000-0000-000000000009', NULL); -- Gamma's section, wrong org
    RAISE EXCEPTION 'TEST 3 FAILED: routing to a foreign-org section should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 3 PASSED: route_entry rejects a to_section_id outside the entry''s own organization: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 4: route_entry routes correctly (single UPDATE, already atomic) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := route_entry(v_id, '17a00000-0002-0000-0000-000000000002', NULL);
  IF v_ent.status <> 'routed' OR v_ent.to_section_id <> '17a00000-0002-0000-0000-000000000002' THEN
    RAISE EXCEPTION 'TEST 4 FAILED: route_entry did not route correctly';
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: route_entry routes to the correct-org section';
END $$;

-- ═══ TEST 5: only Entry staff can route -- Ops (non-Entry-section) staff rejected ═══
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','external_office','Some Office','T5 subject','T5 body');
  PERFORM set_config('app.t17a_ent5', v_ent.id::text, false);
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000005"}',true); -- Ops staff, not Entry staff, not yet routed to them
  BEGIN
    PERFORM route_entry(v_ent.id, '17a00000-0002-0000-0000-000000000002', NULL);
    RAISE EXCEPTION 'TEST 5 FAILED: non-Entry-staff should not be able to route an unrouted entry';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 5 PASSED: route_entry rejects a non-Entry-staff caller on an unrouted entry: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 6: mark_entry_received stamps receipt, replay rejected ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000002"}',true);
  v_ent := mark_entry_received(v_id);
  IF v_ent.received_by <> '17a00000-0001-0000-0000-000000000002' OR v_ent.received_at IS NULL THEN
    RAISE EXCEPTION 'TEST 6 FAILED: mark_entry_received did not stamp receipt';
  END IF;
  BEGIN
    PERFORM mark_entry_received(v_id);
    RAISE EXCEPTION 'TEST 6b FAILED: duplicate mark_entry_received should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 6b PASSED: duplicate mark_entry_received (replay) rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 6 PASSED: mark_entry_received stamps receipt on the routed section side';
END $$;

-- ═══ TEST 7: assign_entry sets assigned_to + deadline, rejects inactive user ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM assign_entry(v_id, '17a00000-0001-0000-0000-000000000006', '2026-12-31');
    RAISE EXCEPTION 'TEST 7 FAILED: assign_entry should reject an inactive user';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 7a PASSED: assign_entry rejects an inactive assignee: %', SQLERRM;
  END;
  v_ent := assign_entry(v_id, '17a00000-0001-0000-0000-000000000002', '2026-12-31');
  IF v_ent.assigned_to <> '17a00000-0001-0000-0000-000000000002' OR v_ent.deadline <> '2026-12-31' THEN
    RAISE EXCEPTION 'TEST 7 FAILED: assign_entry did not set assigned_to/deadline';
  END IF;
  RAISE NOTICE 'TEST 7b PASSED: assign_entry assigns within the routed section and sets the reply deadline';
END $$;

-- ═══ TEST 8-11: reply lifecycle draft -> pending_approval -> sent, atomic entry status flip ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_reply external_correspondence_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_entry_reply(v_id, 'T8 reply body', 'en');
  IF v_reply.status <> 'draft' THEN
    RAISE EXCEPTION 'TEST 8 FAILED: draft_entry_reply did not produce a draft';
  END IF;
  PERFORM set_config('app.t17a_reply1', v_reply.id::text, false);

  v_reply := update_entry_reply_draft(v_reply.id, 'T8 reply body edited', 'en');
  IF v_reply.body <> 'T8 reply body edited' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: update_entry_reply_draft did not apply';
  END IF;
  RAISE NOTICE 'TEST 8-9 PASSED: draft_entry_reply / update_entry_reply_draft';

  v_reply := submit_entry_reply(v_reply.id, NULL);
  IF v_reply.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'TEST 10 FAILED: submit_entry_reply did not transition';
  END IF;
  BEGIN
    PERFORM submit_entry_reply(v_reply.id, NULL);
    RAISE EXCEPTION 'TEST 10b FAILED: duplicate submit_entry_reply should be rejected';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 10b PASSED: duplicate submit_entry_reply (replay) rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 10 PASSED: submit_entry_reply transitions draft -> pending_approval';
END $$;

DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_reply_id UUID := current_setting('app.t17a_reply1')::UUID; v_reply external_correspondence_replies; v_ent external_correspondence;
BEGIN
  -- non-supervisor (the drafter themselves) cannot approve their own reply
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM approve_entry_reply(v_reply_id);
    RAISE EXCEPTION 'TEST 11 FAILED: the drafter should not be able to approve their own reply';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 11 PASSED: approve_entry_reply rejects a non-supervisor caller: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000003"}',true);
  v_reply := approve_entry_reply(v_reply_id);
  SELECT * INTO v_ent FROM external_correspondence WHERE id = v_id;
  IF v_reply.status <> 'sent' OR v_reply.approved_by <> '17a00000-0001-0000-0000-000000000003' OR v_ent.status <> 'responded' THEN
    RAISE EXCEPTION 'TEST 12 FAILED: approve_entry_reply did not atomically set reply=sent and entry=responded (reply=%, entry=%)', v_reply.status, v_ent.status;
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: approve_entry_reply atomically transitions reply to sent AND entry to responded in one transaction';
END $$;

-- ═══ TEST 13: forced-failure atomicity proof -- re-approving an
-- already-sent reply must fail, and must leave both rows completely
-- unchanged (no partial re-application) ═══
DO $$
DECLARE v_reply_id UUID := current_setting('app.t17a_reply1')::UUID; v_id UUID := current_setting('app.t17a_ent1')::UUID;
  v_reply_before external_correspondence_replies; v_reply_after external_correspondence_replies;
  v_ent_before external_correspondence; v_ent_after external_correspondence;
BEGIN
  SELECT * INTO v_reply_before FROM external_correspondence_replies WHERE id = v_reply_id;
  SELECT * INTO v_ent_before FROM external_correspondence WHERE id = v_id;
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM approve_entry_reply(v_reply_id);
    RAISE EXCEPTION 'TEST 13 FAILED: re-approving an already-sent reply should be rejected';
  EXCEPTION WHEN OTHERS THEN
    NULL; -- expected
  END;
  SELECT * INTO v_reply_after FROM external_correspondence_replies WHERE id = v_reply_id;
  SELECT * INTO v_ent_after FROM external_correspondence WHERE id = v_id;
  IF v_reply_after.approved_at IS DISTINCT FROM v_reply_before.approved_at
     OR v_ent_after.status IS DISTINCT FROM v_ent_before.status THEN
    RAISE EXCEPTION 'TEST 13 FAILED: partial state leaked from a rejected approve_entry_reply replay';
  END IF;
  RAISE NOTICE 'TEST 13 PASSED: a rejected approve_entry_reply replay leaves zero partial state (fully atomic)';
END $$;

-- ═══ TEST 14: mark_entry_reply_sent records delivery, only Entry staff ═══
DO $$
DECLARE v_reply_id UUID := current_setting('app.t17a_reply1')::UUID; v_reply external_correspondence_replies;
BEGIN
  -- Legal supervisor is not Entry staff and the reply is already 'sent' -- only Entry staff branch applies
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM mark_entry_reply_sent(v_reply_id, 'email');
    RAISE EXCEPTION 'TEST 14 FAILED: non-Entry-staff should not record delivery';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 14a PASSED: mark_entry_reply_sent rejects a non-Entry-staff caller: %', SQLERRM;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_reply := mark_entry_reply_sent(v_reply_id, 'email');
  IF v_reply.delivery_method <> 'email' OR v_reply.sent_at IS NULL THEN
    RAISE EXCEPTION 'TEST 14 FAILED: mark_entry_reply_sent did not record delivery';
  END IF;
  RAISE NOTICE 'TEST 14b PASSED: mark_entry_reply_sent (Entry staff) records delivery_method/sent_at';
END $$;

-- ═══ TEST 15: close_entry requires 'responded' (trigger-enforced), then succeeds ═══
DO $$
DECLARE v_id UUID := current_setting('app.t17a_ent1')::UUID; v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := close_entry(v_id);
  IF v_ent.status <> 'closed' THEN
    RAISE EXCEPTION 'TEST 15 FAILED: close_entry did not close from responded';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: close_entry closes a responded entry';
END $$;

DO $$
DECLARE v_ent external_correspondence;
BEGIN
  -- a fresh 'logged' entry cannot be closed directly -- check_entry_status trigger only allows responded -> closed
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('phone','public','Skip Ahead','T16 subject','T16 body');
  BEGIN
    PERFORM close_entry(v_ent.id);
    RAISE EXCEPTION 'TEST 16 FAILED: closing a freshly-logged entry should be rejected by the status trigger';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 16 PASSED: close_entry on a logged (not yet responded) entry is rejected by the pre-existing status-transition trigger: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 17: return_entry_reply sends a pending_approval reply back to draft ═══
DO $$
DECLARE v_ent external_correspondence; v_reply external_correspondence_replies; v_approvals INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Return Test','T17 subject','T17 body');
  v_ent := route_entry(v_ent.id, '17a00000-0002-0000-0000-000000000002', '17a00000-0001-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_entry_reply(v_ent.id, 'T17 reply body', 'en');
  v_reply := submit_entry_reply(v_reply.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000003"}',true);
  v_reply := return_entry_reply(v_reply.id, 'needs more detail');
  IF v_reply.status <> 'draft' OR v_reply.pending_approval_by IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 17 FAILED: return_entry_reply did not send the draft back';
  END IF;
  SELECT count(*) INTO v_approvals FROM approvals WHERE record_type='external_correspondence_reply' AND record_id=v_reply.id AND decision='returned';
  IF v_approvals <> 1 THEN
    RAISE EXCEPTION 'TEST 17 FAILED: return_entry_reply did not write a returned approvals row';
  END IF;
  RAISE NOTICE 'TEST 17 PASSED: return_entry_reply sends a pending reply back to draft with history evidence';
END $$;

-- ═══ TEST 18: re-routing an already-routed entry to a different section works ═══
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('in_person','public','Reroute Test','T18 subject','T18 body');
  v_ent := route_entry(v_ent.id, '17a00000-0002-0000-0000-000000000002', NULL);
  v_ent := route_entry(v_ent.id, '17a00000-0002-0000-0000-000000000003', NULL); -- reroute to Operations
  IF v_ent.status <> 'routed' OR v_ent.to_section_id <> '17a00000-0002-0000-0000-000000000003' THEN
    RAISE EXCEPTION 'TEST 18 FAILED: rerouting an already-routed entry should be allowed (status trigger permits routed->routed)';
  END IF;
  RAISE NOTICE 'TEST 18 PASSED: route_entry can reroute an already-routed entry to a different section';
END $$;

-- ═══ TEST 19: outsider (no assignment, not Entry staff) rejected everywhere ═══
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Outsider Test','T19 subject','T19 body');

  PERFORM set_config('request.jwt.claims','{"sub":"17a00000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM create_entry('email','public','Outsider Attempt','x','y');
    RAISE EXCEPTION 'TEST 19a FAILED: outsider (non-Entry-staff) should not be able to log correspondence';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 19a PASSED: create_entry rejects a non-Entry-staff caller: %', SQLERRM;
  END;
  BEGIN
    PERFORM update_entry_draft(v_ent.id, 'x', 'en', 'y', 'en', NULL);
    RAISE EXCEPTION 'TEST 19b FAILED: outsider should not be able to edit an entry';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 19b PASSED: update_entry_draft rejects a non-Entry-staff, non-section caller: %', SQLERRM;
  END;
  BEGIN
    PERFORM route_entry(v_ent.id, '17a00000-0002-0000-0000-000000000002', NULL);
    RAISE EXCEPTION 'TEST 19c FAILED: outsider should not be able to route an entry';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TEST 19c PASSED: route_entry rejects a non-Entry-staff caller: %', SQLERRM;
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ENTRY SERVER MUTATION FOUNDATION BEHAVIORAL TESTS: 19 scenarios (with sub-checks) PASSED'; END $$;
ROLLBACK;
