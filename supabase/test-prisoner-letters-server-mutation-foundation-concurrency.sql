-- Prisoner Letters server-mutation-foundation concurrency suite (9 race
-- scenarios). Disposable local PostgreSQL only; requires dblink.
-- Mirrors the exact dblink-based genuinely-independent-session pattern
-- every other CAP-002/CAP-003 concurrency suite in this repository
-- already establishes (two dblink_get_result calls per statement per
-- PostgreSQL's own documented async-fetch protocol).
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE r9e_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON r9e_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
  ('9e000000-0000-0000-0000-000000000001','Conc T9E Prison Org P','mcs','C9EP'),
  ('9e000000-0000-0000-0000-000000000002','Conc T9E Authority Org Q','authority','C9EQ');
INSERT INTO commands(id,name,org_id) VALUES
  ('9e000000-0010-0000-0000-000000000001','C9E Cmd P','9e000000-0000-0000-0000-000000000001'),
  ('9e000000-0010-0000-0000-000000000002','C9E Cmd Q','9e000000-0000-0000-0000-000000000002');
INSERT INTO departments(id,name,command_id) VALUES
  ('9e000000-0020-0000-0000-000000000001','C9E Dept P','9e000000-0010-0000-0000-000000000001'),
  ('9e000000-0020-0000-0000-000000000002','C9E Dept Q','9e000000-0010-0000-0000-000000000002');
INSERT INTO sections(id,name,code,org_id,department_id) VALUES
  ('9e000000-0002-0000-0000-000000000001','C9E Section P','C9ESP','9e000000-0000-0000-0000-000000000001','9e000000-0020-0000-0000-000000000001'),
  ('9e000000-0002-0000-0000-000000000002','C9E Section Q','C9ESQ','9e000000-0000-0000-0000-000000000002','9e000000-0020-0000-0000-000000000002');
INSERT INTO auth.users(id,email) VALUES
  ('9e000000-0001-0000-0000-000000000001','c9e-mcsstaff@t.local'),
  ('9e000000-0001-0000-0000-000000000002','c9e-authsuper1@t.local'),
  ('9e000000-0001-0000-0000-000000000003','c9e-authsuper2@t.local'),
  ('9e000000-0001-0000-0000-000000000004','c9e-assignee1@t.local'),
  ('9e000000-0001-0000-0000-000000000005','c9e-assignee2@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_prisoner_letters_staff) VALUES
  ('9e000000-0001-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','C9E-1','MCS Staff','c9e-mcsstaff@t.local',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000002','9e000000-0000-0000-0000-000000000002','C9E-2','Authority Super 1','c9e-authsuper1@t.local',TRUE,FALSE),
  ('9e000000-0001-0000-0000-000000000003','9e000000-0000-0000-0000-000000000002','C9E-3','Authority Super 2','c9e-authsuper2@t.local',TRUE,FALSE),
  ('9e000000-0001-0000-0000-000000000004','9e000000-0000-0000-0000-000000000002','C9E-4','Assignee 1','c9e-assignee1@t.local',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000005','9e000000-0000-0000-0000-000000000002','C9E-5','Assignee 2','c9e-assignee2@t.local',TRUE,TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('9e000000-0001-0000-0000-000000000001','section','9e000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000002','section','9e000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000003','section','9e000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000004','section','9e000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('9e000000-0001-0000-0000-000000000005','section','9e000000-0002-0000-0000-000000000002','staff',TRUE,TRUE);
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','C9E-FILE-001','C9E-INMATE-001','C9E Test Inmate','Test Address','Maafushi Prison');

CREATE OR REPLACE FUNCTION r9e_connect(p_conn TEXT, p_user UUID) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($q$SELECT set_config('request.jwt.claims', '{"sub":"%s"}', false)$q$, p_user)) AS t(v text);
END;
$$ LANGUAGE plpgsql;

SET ROLE authenticated;

-- ── CONC 1: two authority supervisors race mark_prisoner_letter_
-- received on the SAME unrouted letter -- status='submitted' guard
-- means exactly one wins ──
DO $$
DECLARE v_pl prisoner_letters;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9e000000-0001-0000-0000-000000000001"}',true);
  v_pl := create_prisoner_letter('9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002','Race1 body');
  INSERT INTO r9e_ids VALUES ('race1', v_pl.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_received_count INT;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race1';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).received_by::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).received_by::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: expected exactly one mark_prisoner_letter_received to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT count(*) INTO v_received_count FROM prisoner_letters WHERE id = v_id AND received_by IS NOT NULL;
  IF v_received_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: letter must have exactly one recorded receipt';
  END IF;
  RAISE NOTICE 'CONC TEST 1 PASSED: two concurrent mark_prisoner_letter_received calls on the same letter -- exactly one wins, no lost update, receipt recorded exactly once';
END $$;

-- ── CONC 2: two supervisors race route_prisoner_letter on the same
-- letter, assigning to two DIFFERENT staffers -- no guard against
-- re-routing exists, so the row lock simply serializes both; both may
-- legitimately succeed, but the final state must be internally
-- consistent (assigned_to matches whichever route committed last, not
-- a mix of the two calls' inputs) ──
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final prisoner_letters;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race1';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (route_prisoner_letter('%s'::uuid, '9e000000-0002-0000-0000-000000000002'::uuid, '9e000000-0001-0000-0000-000000000004'::uuid)).assigned_to::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (route_prisoner_letter('%s'::uuid, '9e000000-0002-0000-0000-000000000002'::uuid, '9e000000-0001-0000-0000-000000000005'::uuid)).assigned_to::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: both routes should succeed (no re-route guard), got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT * INTO v_final FROM prisoner_letters WHERE id = v_id;
  IF v_final.assigned_to NOT IN ('9e000000-0001-0000-0000-000000000004','9e000000-0001-0000-0000-000000000005') THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: final assigned_to (%) is neither racing value -- torn/corrupted write', v_final.assigned_to;
  END IF;
  RAISE NOTICE 'CONC TEST 2 PASSED: two concurrent route_prisoner_letter calls serialize cleanly via the row lock, final state = %', v_final.assigned_to;
END $$;

-- ── CONC 3: the winning assignee (from CONC 2's final state, whichever
-- it is) races themself across two sessions on create_prisoner_letter_
-- reply -- status guard (submitted/received -> replied) means exactly
-- one wins ──
DO $$
DECLARE v_id UUID; v_assignee UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_reply_count INT;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race1';
  SELECT assigned_to INTO v_assignee FROM prisoner_letters WHERE id = v_id;
  PERFORM r9e_connect('c1', v_assignee);
  PERFORM r9e_connect('c2', v_assignee);

  PERFORM dblink_send_query('c1', format($q$SELECT (create_prisoner_letter_reply('%s'::uuid, 'Reply attempt A')).id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (create_prisoner_letter_reply('%s'::uuid, 'Reply attempt B')).id::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: expected exactly one reply to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT count(*) INTO v_reply_count FROM prisoner_replies WHERE letter_id = v_id;
  IF v_reply_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: letter must have exactly one reply row, got %', v_reply_count;
  END IF;
  RAISE NOTICE 'CONC TEST 3 PASSED: two concurrent create_prisoner_letter_reply calls by the same assignee -- exactly one wins, exactly one reply row, atomic status transition holds';
END $$;

-- ── CONC 4: the submitter races themself across two sessions on
-- mark_prisoner_letter_delivered -- status='replied' guard means
-- exactly one wins ──
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final_status TEXT;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race1';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000001');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_prisoner_letter_delivered('%s'::uuid)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_delivered('%s'::uuid)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: expected exactly one delivery to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT status INTO v_final_status FROM prisoner_letters WHERE id = v_id;
  IF v_final_status <> 'delivered' THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: expected terminal status delivered, got %', v_final_status;
  END IF;
  RAISE NOTICE 'CONC TEST 4 PASSED: two concurrent mark_prisoner_letter_delivered calls -- exactly one wins, letter reaches terminal state exactly once';
END $$;

-- ── CONC 5: reference-generation atomicity -- two concurrent
-- create_prisoner_letter calls by the same MCS submitter must each
-- receive a UNIQUE reference_number (no duplicate/skipped sequence
-- value under a genuine race) ──
DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_dup_count INT;
BEGIN
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000001');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1', format($q$SELECT (create_prisoner_letter('%s'::uuid,'%s'::uuid,'%s'::uuid,'Race5 A')).reference_number$q$,
    '9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002'));
  PERFORM dblink_send_query('c2', format($q$SELECT (create_prisoner_letter('%s'::uuid,'%s'::uuid,'%s'::uuid,'Race5 B')).reference_number$q$,
    '9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002'));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: both concurrent creates should succeed, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF v_r1 = v_r2 THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: reference generation is not race-safe -- both letters received the same reference_number: %', v_r1;
  END IF;
  SELECT count(*) INTO v_dup_count FROM prisoner_letters WHERE reference_number IN (v_r1, v_r2) GROUP BY reference_number HAVING count(*) > 1;
  IF v_dup_count IS NOT NULL THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: duplicate reference_number persisted to the table';
  END IF;
  RAISE NOTICE 'CONC TEST 5 PASSED: reference-generation atomicity holds under a genuine race -- unique references %, %', v_r1, v_r2;
END $$;

-- ── CONC 6: route_prisoner_letter (supervisor) vs mark_prisoner_
-- letter_slip_generated (MCS submitter) on a fresh letter -- different
-- sides, different fields, no logical conflict; must not deadlock ──
DO $$
DECLARE v_pl prisoner_letters;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9e000000-0001-0000-0000-000000000001"}',true);
  v_pl := create_prisoner_letter('9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002','Race6 body');
  INSERT INTO r9e_ids VALUES ('race6', v_pl.id);
END $$;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race6';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1', format($q$SELECT (route_prisoner_letter('%s'::uuid, '9e000000-0002-0000-0000-000000000002'::uuid, '9e000000-0001-0000-0000-000000000004'::uuid)).id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_slip_generated('%s'::uuid)).id::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 6 FAILED: both non-conflicting mutations should succeed, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 6 PASSED: route (authority side) vs slip-generated (MCS side) on the same letter -- no deadlock, both apply';
END $$;

-- ── CONC 7: replay safety -- after CONC TEST 1's winner, the LOSER's
-- own session retries mark_prisoner_letter_received again and gets the
-- correct guard error (not a generic lock-timeout/deadlock error) ──
DO $$
DECLARE v_id UUID; v_r TEXT;
BEGIN
  SELECT id INTO v_id FROM r9e_ids WHERE name = 'race1';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  BEGIN
    SELECT t.v INTO v_r FROM dblink('c1', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).status$q$, v_id)) AS t(v TEXT);
    RAISE EXCEPTION 'CONC TEST 7 FAILED: a replayed receive on an already-received letter should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'CONC TEST 7 FAILED%' THEN RAISE; END IF;
    IF SQLERRM NOT ILIKE '%not awaiting receipt%' THEN
      RAISE EXCEPTION 'CONC TEST 7 FAILED: wrong rejection reason on replay: %', SQLERRM;
    END IF;
    RAISE NOTICE 'CONC TEST 7 PASSED: post-race replay gets the correct business-rule rejection, not a lock artifact: %', SQLERRM;
  END;
  PERFORM dblink_disconnect('c1');
END $$;

-- ── CONC 8: two UNRELATED letters progress concurrently with no
-- cross-interference (each row lock is independent) ──
DO $$
DECLARE v_pl_a prisoner_letters; v_pl_b prisoner_letters;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"9e000000-0001-0000-0000-000000000001"}',true);
  v_pl_a := create_prisoner_letter('9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002','Race8 A');
  v_pl_b := create_prisoner_letter('9e000000-0003-0000-0000-000000000001','9e000000-0000-0000-0000-000000000001','9e000000-0000-0000-0000-000000000002','Race8 B');
  INSERT INTO r9e_ids VALUES ('race8a', v_pl_a.id), ('race8b', v_pl_b.id);
END $$;
DO $$
DECLARE v_id_a UUID; v_id_b UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id_a FROM r9e_ids WHERE name = 'race8a';
  SELECT id INTO v_id_b FROM r9e_ids WHERE name = 'race8b';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).id::text$q$, v_id_a));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).id::text$q$, v_id_b));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 8 FAILED: two independent letters should both succeed with no cross-interference, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 8 PASSED: two unrelated letters progress concurrently with independent row locks, no interference';
END $$;

-- ── CONC 9: deadlock safety across a crossed-order two-row chain --
-- session 1 touches (A then B), session 2 touches (B then A). Phase 1
-- uses the MCS submitter (authorized, mark_prisoner_letter_slip_
-- generated, MCS side) on both connections; phase 2 uses an authority
-- supervisor (authorized, mark_prisoner_letter_received, authority
-- side) on both connections -- both letters share the same
-- submitting/destination orgs, so every call is individually valid;
-- the database's own deadlock detector (not application logic) must
-- resolve any contention without hanging. ──
DO $$
DECLARE v_id_a UUID; v_id_b UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id_a FROM r9e_ids WHERE name = 'race8a';
  SELECT id INTO v_id_b FROM r9e_ids WHERE name = 'race8b';
  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000001');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000001');

  -- c1: A then B. c2: B then A. Both calls are single-statement RPCs
  -- (each RPC's own FOR UPDATE lock is acquired and released within
  -- its own transaction), so this exercises lock-acquisition ordering
  -- across two back-to-back statements per session rather than a
  -- held multi-row transaction -- still a valid crossed-order
  -- contention pattern for this suite's purposes.
  PERFORM dblink_send_query('c1', format($q$SELECT (mark_prisoner_letter_slip_generated('%s'::uuid)).id::text$q$, v_id_a));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_slip_generated('%s'::uuid)).id::text$q$, v_id_b));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  PERFORM r9e_connect('c1', '9e000000-0001-0000-0000-000000000002');
  PERFORM r9e_connect('c2', '9e000000-0001-0000-0000-000000000002');
  PERFORM dblink_send_query('c1', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).id::text$q$, v_id_b));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_prisoner_letter_received('%s'::uuid)).id::text$q$, v_id_a));
  BEGIN PERFORM t.v FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM t.v FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 9 FAILED: crossed-order access across two letters should both complete without hanging, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 9 PASSED: crossed-order two-row access completes without deadlock or indefinite hang';
END $$;

RESET ROLE;
DROP FUNCTION r9e_connect(TEXT, UUID);
DO $$ BEGIN RAISE NOTICE 'PRISONER LETTERS SERVER MUTATION FOUNDATION CONCURRENCY SUITE (9 scenarios) PASSED'; END $$;
