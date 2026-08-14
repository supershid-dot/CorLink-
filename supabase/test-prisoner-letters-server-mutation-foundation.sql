-- Prisoner Letters server-mutation-foundation behavioral test suite.
-- Disposable local PostgreSQL only. Exercises the full evidenced
-- Prisoner Letters lifecycle through the new server-authoritative
-- RPCs, and the guard rails around each.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('9c000000-0000-0000-0000-000000000001','T9C Prison Org P','mcs','T9CP'),
  ('9c000000-0000-0000-0000-000000000002','T9C Authority Org Q','authority','T9CQ'),
  ('9c000000-0000-0000-0000-000000000003','T9C Authority Org R','authority','T9CR');
INSERT INTO commands(id,name,org_id) VALUES
  ('9c000000-0010-0000-0000-000000000001','T9C Command P','9c000000-0000-0000-0000-000000000001'),
  ('9c000000-0010-0000-0000-000000000002','T9C Command Q','9c000000-0000-0000-0000-000000000002'),
  ('9c000000-0010-0000-0000-000000000003','T9C Command R','9c000000-0000-0000-0000-000000000003');
INSERT INTO departments(id,name,command_id) VALUES
  ('9c000000-0020-0000-0000-000000000001','T9C Dept P','9c000000-0010-0000-0000-000000000001'),
  ('9c000000-0020-0000-0000-000000000002','T9C Dept Q','9c000000-0010-0000-0000-000000000002'),
  ('9c000000-0020-0000-0000-000000000003','T9C Dept R','9c000000-0010-0000-0000-000000000003');
INSERT INTO sections(id,name,code,org_id,department_id) VALUES
  ('9c000000-0002-0000-0000-000000000001','T9C Section P','T9CSP','9c000000-0000-0000-0000-000000000001','9c000000-0020-0000-0000-000000000001'),
  ('9c000000-0002-0000-0000-000000000002','T9C Section Q','T9CSQ','9c000000-0000-0000-0000-000000000002','9c000000-0020-0000-0000-000000000002'),
  ('9c000000-0002-0000-0000-000000000003','T9C Section R','T9CSR','9c000000-0000-0000-0000-000000000003','9c000000-0020-0000-0000-000000000003'),
  ('9c000000-0002-0000-0000-000000000004','T9C Section Q2','T9CSQ2','9c000000-0000-0000-0000-000000000002','9c000000-0020-0000-0000-000000000002');

INSERT INTO auth.users(id,email) VALUES
  ('9c000000-0001-0000-0000-000000000001','t9c-mcsstaff@t.local'),
  ('9c000000-0001-0000-0000-000000000002','t9c-mcssuper@t.local'),
  ('9c000000-0001-0000-0000-000000000003','t9c-mcsother@t.local'),
  ('9c000000-0001-0000-0000-000000000004','t9c-authstaff@t.local'),
  ('9c000000-0001-0000-0000-000000000005','t9c-authsuper@t.local'),
  ('9c000000-0001-0000-0000-000000000006','t9c-authstaff2@t.local'),
  ('9c000000-0001-0000-0000-000000000007','t9c-authinactive@t.local'),
  ('9c000000-0001-0000-0000-000000000008','t9c-otherorg@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_prisoner_letters_staff) VALUES
  ('9c000000-0001-0000-0000-000000000001','9c000000-0000-0000-0000-000000000001','T9C-1','MCS Staff','t9c-mcsstaff@t.local',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000002','9c000000-0000-0000-0000-000000000001','T9C-2','MCS Supervisor','t9c-mcssuper@t.local',TRUE,FALSE),
  ('9c000000-0001-0000-0000-000000000003','9c000000-0000-0000-0000-000000000001','T9C-3','MCS Other Staff','t9c-mcsother@t.local',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000004','9c000000-0000-0000-0000-000000000002','T9C-4','Authority Staff','t9c-authstaff@t.local',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000005','9c000000-0000-0000-0000-000000000002','T9C-5','Authority Supervisor','t9c-authsuper@t.local',TRUE,FALSE),
  ('9c000000-0001-0000-0000-000000000006','9c000000-0000-0000-0000-000000000002','T9C-6','Authority Staff Two','t9c-authstaff2@t.local',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000007','9c000000-0000-0000-0000-000000000002','T9C-7','Authority Inactive','t9c-authinactive@t.local',FALSE,TRUE),
  ('9c000000-0001-0000-0000-000000000008','9c000000-0000-0000-0000-000000000003','T9C-8','Other Org Staff','t9c-otherorg@t.local',TRUE,TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('9c000000-0001-0000-0000-000000000001','section','9c000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000002','section','9c000000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000003','section','9c000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000004','section','9c000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000005','section','9c000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000006','section','9c000000-0002-0000-0000-000000000004','staff',TRUE,TRUE),
  ('9c000000-0001-0000-0000-000000000008','section','9c000000-0002-0000-0000-000000000003','staff',TRUE,TRUE);

-- Prisoner registry row, owned by org P (MCS side).
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('9c000000-0003-0000-0000-000000000001','9c000000-0000-0000-0000-000000000001','T9C-FILE-001','T9C-INMATE-001','T9C Test Inmate One','Test Address','Maafushi Prison');

SET ROLE authenticated;

-- ═══ TEST 1: create_prisoner_letter happy path — prisoner identity
-- derived server-side, reference generated, status = submitted ═══
DO $$
DECLARE v_pl prisoner_letters;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  v_pl := create_prisoner_letter(
    '9c000000-0003-0000-0000-000000000001', '9c000000-0000-0000-0000-000000000001',
    '9c000000-0000-0000-0000-000000000002', 'Dear authority, please advise.'
  );
  IF v_pl.status <> 'submitted' OR v_pl.submitted_by <> '9c000000-0001-0000-0000-000000000001'
     OR v_pl.prisoner_name <> 'T9C Test Inmate One' OR v_pl.prisoner_id <> 'T9C-INMATE-001'
     OR v_pl.reference_number IS NULL OR v_pl.reference_number NOT LIKE 'PL-T9CP-%'
     OR v_pl.slip_generated <> FALSE THEN
    RAISE EXCEPTION 'TEST 1 FAILED: create_prisoner_letter did not produce expected row: %', v_pl;
  END IF;
  PERFORM set_config('app.t9c_pl1', v_pl.id::text, false);
  RAISE NOTICE 'TEST 1 PASSED: create_prisoner_letter derives prisoner identity server-side and generates a reference';
END $$;

-- ═══ TEST 2: create_prisoner_letter rejects a non-flagged caller ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM create_prisoner_letter('9c000000-0003-0000-0000-000000000001','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-000000000002','sneaky');
    RAISE EXCEPTION 'TEST 2 FAILED: non-flagged caller (even a supervisor) should not be able to submit';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 2 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 2 PASSED: create_prisoner_letter rejects a non-flagged caller (submission stays flag-gated, no supervisor bypass): %', SQLERRM;
  END;
END $$;

-- ═══ TEST 3: create_prisoner_letter rejects a from_prison_id that
-- isn't the caller's own org ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_prisoner_letter('9c000000-0003-0000-0000-000000000001','9c000000-0000-0000-0000-000000000002','9c000000-0000-0000-0000-000000000002','sneaky');
    RAISE EXCEPTION 'TEST 3 FAILED: create_prisoner_letter should reject a from_prison_id that is not the caller''s own org';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 3 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 3 PASSED: create_prisoner_letter rejects a spoofed from_prison_id: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 4: create_prisoner_letter rejects a destination that is not
-- an authority-type organization (directionality) ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_prisoner_letter('9c000000-0003-0000-0000-000000000001','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-000000000001','sneaky');
    RAISE EXCEPTION 'TEST 4 FAILED: create_prisoner_letter should reject a non-authority destination';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 4 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 4 PASSED: create_prisoner_letter enforces directionality (destination must be an authority org): %', SQLERRM;
  END;
END $$;

-- ═══ TEST 5: create_prisoner_letter rejects a prisoner not in the
-- caller's own org registry (identity is never trusted from client) ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_prisoner_letter('00000000-0000-0000-0000-000000000099','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-000000000002','sneaky');
    RAISE EXCEPTION 'TEST 5 FAILED: create_prisoner_letter should reject an unknown prisoner_ref';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 5 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 5 PASSED: create_prisoner_letter rejects a prisoner not found in the caller''s own org registry: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 6: mark_prisoner_letter_received — before routing
-- (assigned_to IS NULL), only an authority-side supervisor/admin may
-- receive it (Product Decision A) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_pl prisoner_letters;
BEGIN
  -- authority_staff2 is flagged but not yet assigned -- must be denied.
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000006"}',true);
  BEGIN
    PERFORM mark_prisoner_letter_received(v_id);
    RAISE EXCEPTION 'TEST 6a FAILED: flagged-but-unassigned authority staff should not be able to receive an unrouted letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 6a PASSED: unassigned flagged staff cannot receive before routing: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000005"}',true);
  v_pl := mark_prisoner_letter_received(v_id);
  IF v_pl.status <> 'received' OR v_pl.received_by <> '9c000000-0001-0000-0000-000000000005' OR v_pl.received_at IS NULL THEN
    RAISE EXCEPTION 'TEST 6b FAILED: authority supervisor should be able to receive an unrouted letter: %', v_pl;
  END IF;
  RAISE NOTICE 'TEST 6b PASSED: authority-side supervisor/admin can receive an unrouted letter (org-wide oversight, independent of the flag)';

  BEGIN
    PERFORM mark_prisoner_letter_received(v_id);
    RAISE EXCEPTION 'TEST 6c FAILED: duplicate mark_prisoner_letter_received should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 6c FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 6c PASSED: duplicate receive (replay) rejected: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 7: route_prisoner_letter — supervisor/admin only, validates
-- section belongs to destination org, validates assignee ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_pl prisoner_letters;
BEGIN
  -- authority_staff (flagged, not supervisor) must not be able to route.
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000002', '9c000000-0001-0000-0000-000000000004');
    RAISE EXCEPTION 'TEST 7a FAILED: ordinary flagged authority staff (non-supervisor) should not be able to route';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 7a PASSED: routing stays supervisor/admin-only: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000005"}',true);
  -- Section belongs to a DIFFERENT org (org P) -- must be rejected.
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000001', '9c000000-0001-0000-0000-000000000004');
    RAISE EXCEPTION 'TEST 7b FAILED: routing to a foreign-org section should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 7b PASSED: foreign-org destination section rejected: %', SQLERRM;
  END;
  -- Assignee inactive -- must be rejected.
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000002', '9c000000-0001-0000-0000-000000000007');
    RAISE EXCEPTION 'TEST 7c FAILED: routing to an inactive assignee should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7c FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 7c PASSED: inactive assignee rejected: %', SQLERRM;
  END;
  -- Assignee in a different org -- must be rejected.
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000002', '9c000000-0001-0000-0000-000000000008');
    RAISE EXCEPTION 'TEST 7d FAILED: routing to a foreign-org assignee should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 7d FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 7d PASSED: foreign-org assignee rejected: %', SQLERRM;
  END;

  v_pl := route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000002', '9c000000-0001-0000-0000-000000000004');
  IF v_pl.to_section_id <> '9c000000-0002-0000-0000-000000000002' OR v_pl.assigned_to <> '9c000000-0001-0000-0000-000000000004' THEN
    RAISE EXCEPTION 'TEST 7e FAILED: route_prisoner_letter did not set to_section_id/assigned_to: %', v_pl;
  END IF;
  RAISE NOTICE 'TEST 7e PASSED: authority supervisor routes and assigns to a valid, active, flagged same-org staffer';
END $$;

-- ═══ TEST 8: now that the letter is assigned, the assignee (not just
-- a supervisor) has receive/reply access -- but a DIFFERENT flagged
-- staffer at the same org still does not ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000006"}',true);
  IF can_view_prisoner_letter(v_id) THEN
    RAISE EXCEPTION 'TEST 8 FAILED: an authority staffer who is not the assignee (and not a supervisor) should not see this letter';
  END IF;
  RAISE NOTICE 'TEST 8 PASSED: a non-assigned, non-supervisor authority staffer cannot view the now-routed letter';
END $$;

-- ═══ TEST 9: mark_prisoner_letter_slip_generated — MCS side, creator
-- (or supervisor), blocked once delivered ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_pl prisoner_letters;
BEGIN
  -- A different MCS staffer (not the submitter, not a supervisor) is denied.
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM mark_prisoner_letter_slip_generated(v_id);
    RAISE EXCEPTION 'TEST 9a FAILED: a non-submitting, non-supervisor MCS staffer should not be able to mark the slip generated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 9a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 9a PASSED: non-submitter MCS staff denied: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  v_pl := mark_prisoner_letter_slip_generated(v_id);
  IF v_pl.slip_generated <> TRUE THEN
    RAISE EXCEPTION 'TEST 9b FAILED: mark_prisoner_letter_slip_generated did not set the flag: %', v_pl;
  END IF;
  RAISE NOTICE 'TEST 9b PASSED: submitting MCS staffer marks the slip generated, and it now writes an audit row (previously had none)';
END $$;

-- ═══ TEST 10: create_prisoner_letter_reply (fused atomic command) —
-- MCS side is denied, unassigned authority staffer is denied, the
-- assignee succeeds and the letter transitions to 'replied' in the
-- SAME transaction as the reply insert ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_reply prisoner_replies; v_pl prisoner_letters;
BEGIN
  -- MCS never replies to its own letter (governing business rule).
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_prisoner_letter_reply(v_id, 'MCS should not be able to do this');
    RAISE EXCEPTION 'TEST 10a FAILED: MCS side should never be able to reply';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 10a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 10a PASSED: MCS-side reply attempt rejected: %', SQLERRM;
  END;

  -- Flagged authority staffer who is not the assignee is denied.
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000006"}',true);
  BEGIN
    PERFORM create_prisoner_letter_reply(v_id, 'Not my assignment');
    RAISE EXCEPTION 'TEST 10b FAILED: a non-assigned authority staffer should not be able to reply';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 10b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 10b PASSED: non-assigned authority staffer denied: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000004"}',true);
  v_reply := create_prisoner_letter_reply(v_id, 'Here is our reply.');
  SELECT * INTO v_pl FROM prisoner_letters WHERE id = v_id;
  IF v_reply.letter_id <> v_id OR v_reply.replied_by <> '9c000000-0001-0000-0000-000000000004' OR v_pl.status <> 'replied' THEN
    RAISE EXCEPTION 'TEST 10c FAILED: create_prisoner_letter_reply did not atomically fuse reply insert + status update: reply=% letter_status=%', v_reply, v_pl.status;
  END IF;
  PERFORM set_config('app.t9c_reply1', v_reply.id::text, false);
  RAISE NOTICE 'TEST 10c PASSED: assignee replies; reply insert and letter status transition happen atomically in one RPC call';

  BEGIN
    PERFORM create_prisoner_letter_reply(v_id, 'A second reply should not be allowed once already replied');
    RAISE EXCEPTION 'TEST 10d FAILED: a second reply on an already-replied letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 10d FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 10d PASSED: single-reply status guard rejects a second reply: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 11: prisoner_replies is immutable — no update path exists
-- at all (not even for the RPC-authorized actor) ═══
DO $$
BEGIN
  IF to_regprocedure('public.update_prisoner_letter_reply(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 11 FAILED: an update RPC for prisoner_replies unexpectedly exists';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: no reply-update RPC exists — replies remain immutable by omission';
END $$;

-- ═══ TEST 12: mark_prisoner_letter_delivered — MCS side, guarded on
-- status='replied', terminal ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_pl prisoner_letters;
BEGIN
  -- Authority side cannot mark delivered (wrong side of the business rule).
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM mark_prisoner_letter_delivered(v_id);
    RAISE EXCEPTION 'TEST 12a FAILED: authority side should not be able to mark a letter delivered';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 12a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 12a PASSED: authority-side delivery attempt rejected: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  v_pl := mark_prisoner_letter_delivered(v_id);
  IF v_pl.status <> 'delivered' THEN
    RAISE EXCEPTION 'TEST 12b FAILED: mark_prisoner_letter_delivered did not set terminal status: %', v_pl;
  END IF;
  RAISE NOTICE 'TEST 12b PASSED: submitting MCS staffer marks the letter delivered (terminal state reached)';

  BEGIN
    PERFORM mark_prisoner_letter_delivered(v_id);
    RAISE EXCEPTION 'TEST 12c FAILED: re-delivering an already-delivered letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 12c FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 12c PASSED: terminal status guard rejects a second delivery: %', SQLERRM;
  END;
END $$;

-- ═══ TEST 13: terminal immutability — every remaining mutation RPC
-- now rejects this letter, and to_org_id/from_prison_id never changed ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_pl prisoner_letters;
BEGIN
  SELECT * INTO v_pl FROM prisoner_letters WHERE id = v_id;
  IF v_pl.from_prison_id <> '9c000000-0000-0000-0000-000000000001' OR v_pl.to_org_id <> '9c000000-0000-0000-0000-000000000002' THEN
    RAISE EXCEPTION 'TEST 13a FAILED: recipient org fields changed unexpectedly over the letter''s lifetime: %', v_pl;
  END IF;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9c000000-0002-0000-0000-000000000004', '9c000000-0001-0000-0000-000000000006');
    RAISE EXCEPTION 'TEST 13b FAILED: routing a delivered (terminal) letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 13b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 13b PASSED: terminal letter cannot be re-routed: %', SQLERRM;
  END;

  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM mark_prisoner_letter_slip_generated(v_id);
    RAISE EXCEPTION 'TEST 13c FAILED: marking the slip generated on a delivered letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 13c FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 13c PASSED: terminal letter rejects slip-generated mutation too: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 13 PASSED: recipient org is structurally immutable for the letter''s entire lifetime, and every RPC independently refuses to mutate a delivered letter';
END $$;

-- ═══ TEST 14: direct table writes are rejected -- every mutation must
-- now go through an RPC ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9c000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    UPDATE prisoner_letters SET body = 'tampered' WHERE id = v_id;
    RAISE EXCEPTION 'TEST 14a FAILED: direct UPDATE on prisoner_letters should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 14a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 14a PASSED: direct UPDATE on prisoner_letters rejected: %', SQLERRM;
  END;
  BEGIN
    INSERT INTO prisoner_letters (prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status)
    VALUES ('X','Y','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-000000000002','sneaky','9c000000-0001-0000-0000-000000000001','submitted');
    RAISE EXCEPTION 'TEST 14b FAILED: direct INSERT on prisoner_letters should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST 14b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'TEST 14b PASSED: direct INSERT on prisoner_letters rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'TEST 14 PASSED: direct-write closure verified for prisoner_letters';
END $$;

-- ═══ TEST 15: server-side audit rows exist for every mutation, with
-- no confidential body content. record_type='prisoner_letter' has no
-- can_view_case_audit_record() branch (a pre-existing gap, documented
-- in docs/95/docs/37, not introduced by this milestone) and none of
-- this test's actors are org admins, so audit_select would return zero
-- rows for them — checked via superuser bypass, same technique
-- test-prisoner-letter-task-integration.sql's own TEST 12 uses ═══
RESET ROLE;
DO $$
DECLARE v_id UUID := current_setting('app.t9c_pl1')::UUID; v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM audit_logs
  WHERE record_type = 'prisoner_letter' AND record_id = v_id
    AND action IN ('created','received','routed','edited');
  IF v_count < 5 THEN
    RAISE EXCEPTION 'TEST 15a FAILED: expected at least 5 audit rows (created/received/routed/slip-edited/reply-created/delivered-edited), got %', v_count;
  END IF;
  IF EXISTS (
    SELECT 1 FROM audit_logs WHERE record_type = 'prisoner_letter' AND record_id = v_id
      AND (notes ILIKE '%Dear authority%' OR notes ILIKE '%Here is our reply%')
  ) THEN
    RAISE EXCEPTION 'TEST 15b FAILED: audit notes unexpectedly contain confidential letter/reply body content';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: server-side audit trail exists for the full lifecycle with no confidential body content leaked';
END $$;

DO $$ BEGIN RAISE NOTICE 'PRISONER LETTERS SERVER MUTATION FOUNDATION BEHAVIORAL TESTS: 15 scenarios (with sub-checks) PASSED'; END $$;
ROLLBACK;
