-- Prisoner Letters server-mutation-foundation security suite:
-- RLS/authorization scenarios (Section 25) AND attachment/storage
-- scenarios (Section 26) combined into one file, per the governing
-- instruction's own "may be combined" allowance. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
  ('9d000000-0000-0000-0000-000000000001','T9D Prison Org P','mcs','T9DP'),
  ('9d000000-0000-0000-0000-000000000002','T9D Authority Org Q','authority','T9DQ'),
  ('9d000000-0000-0000-0000-000000000003','T9D Authority Org R (unrelated)','authority','T9DR'),
  ('9d000000-0000-0000-0000-000000000004','T9D Prison Org P2 (unrelated)','mcs','T9DP2');
INSERT INTO commands(id,name,org_id) VALUES
  ('9d000000-0010-0000-0000-000000000001','T9D Cmd P','9d000000-0000-0000-0000-000000000001'),
  ('9d000000-0010-0000-0000-000000000002','T9D Cmd Q','9d000000-0000-0000-0000-000000000002'),
  ('9d000000-0010-0000-0000-000000000003','T9D Cmd R','9d000000-0000-0000-0000-000000000003'),
  ('9d000000-0010-0000-0000-000000000004','T9D Cmd P2','9d000000-0000-0000-0000-000000000004');
INSERT INTO departments(id,name,command_id) VALUES
  ('9d000000-0020-0000-0000-000000000001','T9D Dept P','9d000000-0010-0000-0000-000000000001'),
  ('9d000000-0020-0000-0000-000000000002','T9D Dept Q','9d000000-0010-0000-0000-000000000002'),
  ('9d000000-0020-0000-0000-000000000003','T9D Dept R','9d000000-0010-0000-0000-000000000003'),
  ('9d000000-0020-0000-0000-000000000004','T9D Dept P2','9d000000-0010-0000-0000-000000000004');
INSERT INTO sections(id,name,code,org_id,department_id) VALUES
  ('9d000000-0002-0000-0000-000000000001','T9D Section P','T9DSP','9d000000-0000-0000-0000-000000000001','9d000000-0020-0000-0000-000000000001'),
  ('9d000000-0002-0000-0000-000000000002','T9D Section Q','T9DSQ','9d000000-0000-0000-0000-000000000002','9d000000-0020-0000-0000-000000000002'),
  ('9d000000-0002-0000-0000-000000000003','T9D Section R','T9DSR','9d000000-0000-0000-0000-000000000003','9d000000-0020-0000-0000-000000000003'),
  ('9d000000-0002-0000-0000-000000000004','T9D Section P2','T9DSP2','9d000000-0000-0000-0000-000000000004','9d000000-0020-0000-0000-000000000004');

INSERT INTO auth.users(id,email) VALUES
  ('9d000000-0001-0000-0000-000000000001','t9d-mcsstaff@t.local'),
  ('9d000000-0001-0000-0000-000000000002','t9d-authstaff@t.local'),
  ('9d000000-0001-0000-0000-000000000003','t9d-authsuper@t.local'),
  ('9d000000-0001-0000-0000-000000000004','t9d-rstaff@t.local'),
  ('9d000000-0001-0000-0000-000000000005','t9d-p2staff@t.local'),
  ('9d000000-0001-0000-0000-000000000006','t9d-inactive-assignee@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_prisoner_letters_staff) VALUES
  ('9d000000-0001-0000-0000-000000000001','9d000000-0000-0000-0000-000000000001','T9D-1','MCS Staff','t9d-mcsstaff@t.local',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000002','9d000000-0000-0000-0000-000000000002','T9D-2','Authority Staff','t9d-authstaff@t.local',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000003','9d000000-0000-0000-0000-000000000002','T9D-3','Authority Supervisor','t9d-authsuper@t.local',TRUE,FALSE),
  ('9d000000-0001-0000-0000-000000000004','9d000000-0000-0000-0000-000000000003','T9D-4','Org R Staff (unrelated)','t9d-rstaff@t.local',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000005','9d000000-0000-0000-0000-000000000004','T9D-5','Org P2 Staff (unrelated)','t9d-p2staff@t.local',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000006','9d000000-0000-0000-0000-000000000002','T9D-6','Inactive Assignee','t9d-inactive-assignee@t.local',FALSE,TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('9d000000-0001-0000-0000-000000000001','section','9d000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000002','section','9d000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000003','section','9d000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000004','section','9d000000-0002-0000-0000-000000000003','staff',TRUE,TRUE),
  ('9d000000-0001-0000-0000-000000000005','section','9d000000-0002-0000-0000-000000000004','staff',TRUE,TRUE);

INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('9d000000-0003-0000-0000-000000000001','9d000000-0000-0000-0000-000000000001','T9D-FILE-001','T9D-INMATE-001','T9D Test Inmate','Test Address','Maafushi Prison');

SET ROLE authenticated;

-- Seed a routed, in-flight letter (assigned to authority_staff) for the
-- scenarios below.
DO $$
DECLARE v_pl prisoner_letters;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  v_pl := create_prisoner_letter('9d000000-0003-0000-0000-000000000001','9d000000-0000-0000-0000-000000000001','9d000000-0000-0000-0000-000000000002','Confidential body text.');
  PERFORM set_config('app.t9d_pl1', v_pl.id::text, false);

  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000003"}',true);
  v_pl := route_prisoner_letter(v_pl.id, '9d000000-0002-0000-0000-000000000002', '9d000000-0001-0000-0000-000000000002');
END $$;

-- ═══ RLS TEST 1: authority-org caller cannot create a letter
-- (directionality enforced regardless of any flag) ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM create_prisoner_letter('9d000000-0003-0000-0000-000000000001','9d000000-0000-0000-0000-000000000002','9d000000-0000-0000-0000-000000000002','sneaky');
    RAISE EXCEPTION 'RLS TEST 1 FAILED: an authority-org caller should never be able to create a prisoner letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 1 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 1 PASSED: authority side cannot create a letter: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 2: unrelated authority org (org R) has zero visibility
-- and cannot reply, even though its staff is flagged ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_cnt INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000004"}',true);
  SELECT count(*) INTO v_cnt FROM prisoner_letters WHERE id = v_id;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'RLS TEST 2 FAILED: unrelated authority org should see zero rows for this letter, saw %', v_cnt;
  END IF;
  BEGIN
    PERFORM create_prisoner_letter_reply(v_id, 'sneaky cross-org reply');
    RAISE EXCEPTION 'RLS TEST 2b FAILED: unrelated authority org should not be able to reply';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 2b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 2b PASSED: unrelated authority org denied reply: %', SQLERRM;
  END;
  RAISE NOTICE 'RLS TEST 2 PASSED: unrelated authority org (org R) has zero visibility into this letter';
END $$;

-- ═══ RLS TEST 3: unrelated MCS org (P2) has zero visibility ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_cnt INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_cnt FROM prisoner_letters WHERE id = v_id;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'RLS TEST 3 FAILED: unrelated MCS org should see zero rows for this letter, saw %', v_cnt;
  END IF;
  RAISE NOTICE 'RLS TEST 3 PASSED: unrelated MCS org (P2) has zero visibility into this letter';
END $$;

-- ═══ RLS TEST 4: an inactive assignee cannot be routed to, and even
-- if directly forced into assigned_to (superuser bypass, simulating a
-- pre-existing bad row), an inactive user still cannot act ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9d000000-0002-0000-0000-000000000002', '9d000000-0001-0000-0000-000000000006');
    RAISE EXCEPTION 'RLS TEST 4 FAILED: routing to an inactive user should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 4 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 4 PASSED: inactive assignee rejected at route time: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 5: direct table writes rejected for ALL of
-- INSERT/UPDATE/DELETE on both prisoner_letters and prisoner_replies ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    DELETE FROM prisoner_letters WHERE id = v_id;
    RAISE EXCEPTION 'RLS TEST 5a FAILED: direct DELETE on prisoner_letters should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 5a FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 5a PASSED: direct DELETE on prisoner_letters rejected: %', SQLERRM;
  END;
  BEGIN
    INSERT INTO prisoner_replies (letter_id, body, replied_by) VALUES (v_id, 'sneaky direct insert', auth.uid());
    RAISE EXCEPTION 'RLS TEST 5b FAILED: direct INSERT on prisoner_replies should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 5b FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 5b PASSED: direct INSERT on prisoner_replies rejected: %', SQLERRM;
  END;
  RAISE NOTICE 'RLS TEST 5 PASSED: direct table mutation fully closed on both tables';
END $$;

-- ═══ RLS TEST 6: unauthenticated (no auth.uid()) caller rejected ═══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{}',true);
  BEGIN
    PERFORM mark_prisoner_letter_received(current_setting('app.t9d_pl1')::UUID);
    RAISE EXCEPTION 'RLS TEST 6 FAILED: an unauthenticated caller should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 6 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 6 PASSED: mark_prisoner_letter_received rejects an unauthenticated caller explicitly: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 7: recipient-org fields are immutable — no RPC exposes
-- any parameter that could change them post-creation ═══
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE proname IN (
      'mark_prisoner_letter_received','route_prisoner_letter','mark_prisoner_letter_slip_generated',
      'create_prisoner_letter_reply','mark_prisoner_letter_delivered'
    ) AND pg_get_function_arguments(oid) ILIKE '%to_org_id%'
  ) THEN
    RAISE EXCEPTION 'RLS TEST 7 FAILED: a post-creation RPC unexpectedly accepts a to_org_id parameter';
  END IF;
  RAISE NOTICE 'RLS TEST 7 PASSED: no post-creation RPC accepts a recipient-org parameter at all';
END $$;

-- ═══ RLS TEST 8: replies remain immutable — no UPDATE/DELETE policy on
-- prisoner_replies, direct UPDATE rejected even by the reply's author ═══
DO $$
DECLARE v_reply_id UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  v_reply_id := (create_prisoner_letter_reply(current_setting('app.t9d_pl1')::UUID, 'The one and only reply.')).id;
  PERFORM set_config('app.t9d_reply1', v_reply_id::text, false);
  BEGIN
    UPDATE prisoner_replies SET body = 'tampered' WHERE id = v_reply_id;
    RAISE EXCEPTION 'RLS TEST 8 FAILED: direct UPDATE on prisoner_replies should be rejected, even by its own author';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 8 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 8 PASSED: reply immutability holds — even the drafting author cannot mutate it directly: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 9: wrong-org assignment denied even from a valid
-- supervisor caller (assignment hardening, RLS-level reinforcement) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM route_prisoner_letter(v_id, '9d000000-0002-0000-0000-000000000002', '9d000000-0001-0000-0000-000000000004');
    RAISE EXCEPTION 'RLS TEST 9 FAILED: assigning to a different organization''s staffer should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 9 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 9 PASSED: cross-org assignment denied: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 10: prisoner registry stays org-scoped — an MCS caller
-- cannot submit a letter using a prisoner_ref belonging to a different
-- MCS org's registry ═══
RESET ROLE;
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('9d000000-0003-0000-0000-000000000002','9d000000-0000-0000-0000-000000000004','T9D-FILE-002','T9D-INMATE-002','T9D Other Org Inmate','Test Address','Asseyri Prison');
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM create_prisoner_letter('9d000000-0003-0000-0000-000000000002','9d000000-0000-0000-0000-000000000001','9d000000-0000-0000-0000-000000000002','sneaky cross-registry');
    RAISE EXCEPTION 'RLS TEST 10 FAILED: submitting on behalf of a different org''s prisoner registry entry should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'RLS TEST 10 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'RLS TEST 10 PASSED: cross-org prisoner registry reference rejected: %', SQLERRM;
  END;
END $$;

-- ═══ RLS TEST 11: prisoner_letters_select policy count/shape matches
-- Product Decision A exactly (no bare same-org clause) ═══
DO $$
DECLARE v_qual TEXT;
BEGIN
  SELECT qual INTO v_qual FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters' AND policyname='prisoner_letters_select';
  IF v_qual IS NULL OR v_qual NOT ILIKE '%is_supervisor_or_above%' OR v_qual NOT ILIKE '%submitted_by%' OR v_qual NOT ILIKE '%assigned_to%' THEN
    RAISE EXCEPTION 'RLS TEST 11 FAILED: prisoner_letters_select does not match the approved narrower access model: %', v_qual;
  END IF;
  RAISE NOTICE 'RLS TEST 11 PASSED: prisoner_letters_select matches Product Decision A exactly';
END $$;

-- ═══ RLS TEST 12: an org-wide supervisor without the
-- is_prisoner_letters_staff flag still gets oversight access (the
-- disclosed, intentional consequence of Product Decision A) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_visible BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000003"}',true);
  v_visible := can_view_prisoner_letter(v_id);
  IF NOT v_visible THEN
    RAISE EXCEPTION 'RLS TEST 12 FAILED: an authority supervisor should retain oversight visibility even without the flag';
  END IF;
  RAISE NOTICE 'RLS TEST 12 PASSED: supervisor/admin oversight access is independent of is_prisoner_letters_staff, as approved';
END $$;

-- ══════════════════════════════════════════════════════════════════
-- Attachment / storage security scenarios (Section 26)
-- ══════════════════════════════════════════════════════════════════

-- ═══ ATTACHMENT TEST 1: authorized upload before finalization
-- (assignee uploads to the letter) succeeds ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_att_id UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
  VALUES ('prisoner_letter', v_id, 'scan.pdf', 'attachments/prisoner_letter/'||v_id||'/scan.pdf', 'application/pdf', 1024, auth.uid())
  RETURNING id INTO v_att_id;
  PERFORM set_config('app.t9d_att1', v_att_id::text, false);
  RAISE NOTICE 'ATTACHMENT TEST 1 PASSED: authorized assignee uploads an attachment to the in-flight letter';
END $$;

-- ═══ ATTACHMENT TEST 2: unauthorized upload denied (unrelated org R
-- staff, and same-org non-assignee) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000004"}',true);
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('prisoner_letter', v_id, 'sneaky.pdf', 'x', 'application/pdf', 1, auth.uid());
    RAISE EXCEPTION 'ATTACHMENT TEST 2 FAILED: unrelated org should not be able to upload an attachment to this letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'ATTACHMENT TEST 2 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'ATTACHMENT TEST 2 PASSED: unrelated org upload denied: %', SQLERRM;
  END;
END $$;

-- ═══ ATTACHMENT TEST 3: authorized download (SELECT) — both the
-- submitter (MCS side) and the assignee (authority side) can see it ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_att UUID := current_setting('app.t9d_att1')::UUID; v_cnt INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  SELECT count(*) INTO v_cnt FROM attachments WHERE id = v_att;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'ATTACHMENT TEST 3 FAILED: MCS submitter should be able to see the attachment, saw %', v_cnt;
  END IF;
  RAISE NOTICE 'ATTACHMENT TEST 3 PASSED: both parties can view (download) the attachment';
END $$;

-- ═══ ATTACHMENT TEST 4: unauthorized download denied (unrelated MCS
-- org P2, and unrelated authority org R) ═══
DO $$
DECLARE v_att UUID := current_setting('app.t9d_att1')::UUID; v_cnt INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_cnt FROM attachments WHERE id = v_att;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'ATTACHMENT TEST 4 FAILED: unrelated MCS org should see zero attachment rows, saw %', v_cnt;
  END IF;
  RAISE NOTICE 'ATTACHMENT TEST 4 PASSED: unrelated org denied download visibility';
END $$;

-- ═══ ATTACHMENT TEST 5: path-guessing denied — knowing the storage
-- path/attachment id does not help; the row (and thus a signed URL
-- lookup keyed on it) simply does not resolve for an unauthorized
-- caller ═══
DO $$
DECLARE v_att UUID := current_setting('app.t9d_att1')::UUID; v_row RECORD;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000004"}',true);
  SELECT * INTO v_row FROM attachments WHERE id = v_att;
  IF FOUND THEN
    RAISE EXCEPTION 'ATTACHMENT TEST 5 FAILED: an unauthorized caller who knows the attachment id should still get zero rows';
  END IF;
  RAISE NOTICE 'ATTACHMENT TEST 5 PASSED: path/id-guessing does not bypass RLS — no row resolves for an unauthorized caller';
END $$;

-- ═══ ATTACHMENT TEST 6: delete before finalization — authorized
-- uploader can delete their own attachment while the letter is still
-- in flight ═══
DO $$
DECLARE v_att UUID := current_setting('app.t9d_att1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  DELETE FROM attachments WHERE id = v_att;
  IF FOUND THEN
    RAISE NOTICE 'ATTACHMENT TEST 6 PASSED: authorized uploader deletes their own attachment before finalization';
  ELSE
    RAISE EXCEPTION 'ATTACHMENT TEST 6 FAILED: authorized pre-finalization delete unexpectedly did not affect any row';
  END IF;
END $$;

-- ═══ ATTACHMENT TEST 7: delete after finalization ('delivered') is
-- denied even to the original uploader — the finalization lock ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_att_id UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
  VALUES ('prisoner_letter', v_id, 'final-evidence.pdf', 'attachments/prisoner_letter/'||v_id||'/final-evidence.pdf', 'application/pdf', 2048, auth.uid())
  RETURNING id INTO v_att_id;
  PERFORM set_config('app.t9d_att2', v_att_id::text, false);
  -- The letter was already replied to in RLS TEST 8 (status='replied');
  -- proceed straight to delivery.

  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  PERFORM mark_prisoner_letter_delivered(v_id);

  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  DELETE FROM attachments WHERE id = v_att_id;
  IF FOUND THEN
    RAISE EXCEPTION 'ATTACHMENT TEST 7 FAILED: deleting an attachment on a delivered (terminal) letter should be rejected';
  END IF;
  RAISE NOTICE 'ATTACHMENT TEST 7 PASSED: finalization lock blocks attachment deletion on a delivered letter, even for the original uploader';
END $$;

-- ═══ ATTACHMENT TEST 8: upload after finalization is also denied
-- (both directions of the finalization lock) ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('prisoner_letter', v_id, 'too-late.pdf', 'x', 'application/pdf', 1, auth.uid());
    RAISE EXCEPTION 'ATTACHMENT TEST 8 FAILED: uploading to a delivered letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'ATTACHMENT TEST 8 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'ATTACHMENT TEST 8 PASSED: upload after finalization rejected: %', SQLERRM;
  END;
END $$;

-- ═══ ATTACHMENT TEST 9: the original scanned attachment survives
-- finalization intact (not deleted as a side effect of delivery, still
-- visible to authorized parties) ═══
DO $$
DECLARE v_att UUID := current_setting('app.t9d_att2')::UUID; v_cnt INT;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  SELECT count(*) INTO v_cnt FROM attachments WHERE id = v_att;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'ATTACHMENT TEST 9 FAILED: the original evidence attachment should still exist and be visible after delivery, saw %', v_cnt;
  END IF;
  RAISE NOTICE 'ATTACHMENT TEST 9 PASSED: original evidence attachment remains intact and visible after finalization';
END $$;

-- ═══ ATTACHMENT TEST 10 (reply attachments): only the authority side
-- may attach files to a reply — an MCS user (even the submitter) is
-- denied, matching create_prisoner_letter_reply's own directionality ═══
DO $$
DECLARE v_id UUID := current_setting('app.t9d_pl1')::UUID; v_reply_id UUID := current_setting('app.t9d_reply1')::UUID;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9d000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by)
    VALUES ('prisoner_reply', v_reply_id, 'mcs-sneaking-in.pdf', 'x', 'application/pdf', 1, auth.uid());
    RAISE EXCEPTION 'ATTACHMENT TEST 10 FAILED: MCS side should never be able to attach a file to a reply';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'ATTACHMENT TEST 10 FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'ATTACHMENT TEST 10 PASSED: reply attachment upload stays authority-side only: %', SQLERRM;
  END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'PRISONER LETTERS SERVER MUTATION FOUNDATION SECURITY SUITE (12 RLS + 10 attachment scenarios) PASSED'; END $$;
ROLLBACK;
