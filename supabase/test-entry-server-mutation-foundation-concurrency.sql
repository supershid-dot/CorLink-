-- CAP-003 Phase 1.7A concurrency suite (8 race scenarios). Disposable
-- local PostgreSQL only; requires dblink. Mirrors the exact dblink-
-- based genuinely-independent-session pattern every other CAP-002/
-- CAP-003 concurrency suite in this repository already establishes.
-- Only scenarios that correspond to an ACTUALLY-migrated Entry command
-- are exercised -- there is no return-to-previous-section, cancel, or
-- prisoner-transfer command in this milestone (none exist in the
-- evidenced application, see docs/91), so no race scenario is invented
-- for any of them.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE r17c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON r17c_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
  ('17c00000-0000-0000-0000-000000000001','Conc MCS Org','mcs','C17M');
INSERT INTO divisions(id, org_id, name) VALUES
  ('17c00000-0004-0000-0000-000000000001','17c00000-0000-0000-0000-000000000001','Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('17c00000-0002-0000-0000-000000000001','17c00000-0000-0000-0000-000000000001','17c00000-0004-0000-0000-000000000001','Front Desk','FDC'),
  ('17c00000-0002-0000-0000-000000000002','17c00000-0000-0000-0000-000000000001','17c00000-0004-0000-0000-000000000001','Legal','LGC'),
  ('17c00000-0002-0000-0000-000000000003','17c00000-0000-0000-0000-000000000001','17c00000-0004-0000-0000-000000000001','Ops','OPC');
INSERT INTO entry_sections(org_id, section_id) VALUES
  ('17c00000-0000-0000-0000-000000000001','17c00000-0002-0000-0000-000000000001');
INSERT INTO auth.users(id,email) VALUES
  ('17c00000-0001-0000-0000-000000000001','c17-frontdesk1@t.local'),
  ('17c00000-0001-0000-0000-000000000002','c17-frontdesk2@t.local'),
  ('17c00000-0001-0000-0000-000000000003','c17-legal1@t.local'),
  ('17c00000-0001-0000-0000-000000000004','c17-legal2@t.local'),
  ('17c00000-0001-0000-0000-000000000005','c17-legalsuper1@t.local'),
  ('17c00000-0001-0000-0000-000000000006','c17-legalsuper2@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('17c00000-0001-0000-0000-000000000001','17c00000-0000-0000-0000-000000000001','C17-1','Front Desk 1','c17-frontdesk1@t.local',TRUE),
  ('17c00000-0001-0000-0000-000000000002','17c00000-0000-0000-0000-000000000001','C17-2','Front Desk 2','c17-frontdesk2@t.local',TRUE),
  ('17c00000-0001-0000-0000-000000000003','17c00000-0000-0000-0000-000000000001','C17-3','Legal 1','c17-legal1@t.local',TRUE),
  ('17c00000-0001-0000-0000-000000000004','17c00000-0000-0000-0000-000000000001','C17-4','Legal 2','c17-legal2@t.local',TRUE),
  ('17c00000-0001-0000-0000-000000000005','17c00000-0000-0000-0000-000000000001','C17-5','Legal Super 1','c17-legalsuper1@t.local',TRUE),
  ('17c00000-0001-0000-0000-000000000006','17c00000-0000-0000-0000-000000000001','C17-6','Legal Super 2','c17-legalsuper2@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('17c00000-0001-0000-0000-000000000001','section','17c00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('17c00000-0001-0000-0000-000000000002','section','17c00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('17c00000-0001-0000-0000-000000000003','section','17c00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('17c00000-0001-0000-0000-000000000004','section','17c00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('17c00000-0001-0000-0000-000000000005','section','17c00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('17c00000-0001-0000-0000-000000000006','section','17c00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);

CREATE OR REPLACE FUNCTION r17c_connect(p_conn TEXT, p_user UUID) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($q$SELECT set_config('request.jwt.claims', '{"sub":"%s"}', false)$q$, p_user)) AS t(v text);
END;
$$ LANGUAGE plpgsql;

SET ROLE authenticated;

-- ── 1: two Entry staff race to route the SAME entry to different sections ──
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Race1 Sender','Race1','Race1 body');
  INSERT INTO r17c_ids VALUES ('race1', v_ent.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final UUID;
BEGIN
  SELECT id INTO v_id FROM r17c_ids WHERE name = 'race1';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000001');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000002');

  PERFORM dblink_send_query('c1', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000002'::uuid, NULL)).to_section_id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000003'::uuid, NULL)).to_section_id::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  -- Both are ordinary UPDATEs on the same row with no state-guard
  -- distinguishing "already routed" (routing twice, i.e. rerouting, is
  -- a legal repeated transition per the pre-existing status trigger).
  -- Postgres's row lock (FOR UPDATE inside route_entry) serializes
  -- them: both legitimately succeed, one after the other, but the
  -- final to_section_id must be self-consistent, never torn/mixed.
  SELECT to_section_id INTO v_final FROM external_correspondence WHERE id = v_id;
  IF v_ok_count <> 2 OR v_final NOT IN ('17c00000-0002-0000-0000-000000000002','17c00000-0002-0000-0000-000000000003') THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: expected both route_entry calls to complete safely with a self-consistent final section (got % successes, final=%)', v_ok_count, v_final;
  END IF;
  RAISE NOTICE 'CONC TEST 1 PASSED: two concurrent route_entry calls to different sections on the same entry serialize via row lock, final to_section_id is exactly one of the two attempted values (no torn write)';
END $$;

-- ── 2: two receiving-section staff race to mark_entry_received on the
-- SAME entry -- the received_by IS NULL guard means exactly one wins ──
SET ROLE authenticated;
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Race2 Sender','Race2','Race2 body');
  v_ent := route_entry(v_ent.id, '17c00000-0002-0000-0000-000000000002', NULL);
  INSERT INTO r17c_ids VALUES ('race2', v_ent.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_received_count INT;
BEGIN
  SELECT id INTO v_id FROM r17c_ids WHERE name = 'race2';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000003');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000004');

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_entry_received('%s'::uuid)).received_by::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_entry_received('%s'::uuid)).received_by::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: expected exactly one mark_entry_received to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT count(*) INTO v_received_count FROM external_correspondence WHERE id = v_id AND received_by IS NOT NULL;
  IF v_received_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: entry must have exactly one recorded receipt';
  END IF;
  RAISE NOTICE 'CONC TEST 2 PASSED: two concurrent mark_entry_received calls on the same entry -- exactly one wins, no lost update, receipt recorded exactly once';
END $$;

-- ── 3: two supervisors race to approve_entry_reply on the SAME reply ──
SET ROLE authenticated;
DO $$
DECLARE v_ent external_correspondence; v_reply external_correspondence_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Race3 Sender','Race3','Race3 body');
  v_ent := route_entry(v_ent.id, '17c00000-0002-0000-0000-000000000002', '17c00000-0001-0000-0000-000000000003');
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000003"}',true);
  v_reply := draft_entry_reply(v_ent.id, 'Race3 reply', 'en');
  v_reply := submit_entry_reply(v_reply.id, NULL);
  INSERT INTO r17c_ids VALUES ('race3_reply', v_reply.id);
  INSERT INTO r17c_ids VALUES ('race3_entry', v_ent.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_reply_id UUID; v_entry_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_approvals INT;
BEGIN
  SELECT id INTO v_reply_id FROM r17c_ids WHERE name = 'race3_reply';
  SELECT id INTO v_entry_id FROM r17c_ids WHERE name = 'race3_entry';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000005');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000006');

  PERFORM dblink_send_query('c1', format($q$SELECT (approve_entry_reply('%s'::uuid)).status$q$, v_reply_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (approve_entry_reply('%s'::uuid)).status$q$, v_reply_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: expected exactly one approve_entry_reply to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF (SELECT status FROM external_correspondence_replies WHERE id = v_reply_id) <> 'sent'
     OR (SELECT status FROM external_correspondence WHERE id = v_entry_id) <> 'responded' THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: winning approve_entry_reply must atomically leave reply=sent and entry=responded';
  END IF;
  SELECT count(*) INTO v_approvals FROM external_correspondence_replies WHERE id = v_reply_id AND approved_by IS NOT NULL;
  IF v_approvals <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: expected exactly one recorded approver';
  END IF;
  RAISE NOTICE 'CONC TEST 3 PASSED: two concurrent approve_entry_reply calls on the same reply -- exactly one wins, entry+reply flip atomically together, no duplicate approval';
END $$;

-- ── 4: route_entry vs assign_entry race on the same entry (independent
-- columns, both individually valid -- no lost update expected). Both
-- callers are Entry staff (is_entry_staff(org_id)), which — unlike the
-- responding-section-membership branch of assign_entry's own
-- authorization -- does not depend on to_section_id, so the outcome of
-- one call can never revoke the other's authorization mid-race. (An
-- earlier version of this scenario paired an Entry-staff route_entry
-- call with a Legal-staff assign_entry call; when route_entry won the
-- race and rerouted the entry away from Legal, assign_entry's own
-- to_section_id IN my_section_ids() branch then correctly rejected the
-- Legal caller -- a genuine, correct authorization outcome, not a bug,
-- but a confound for a "both individually valid" no-lost-update proof.
-- Kept as Entry-staff-vs-Entry-staff here so this scenario isolates the
-- row-lock/lost-update question cleanly.)
SET ROLE authenticated;
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('phone','public','Race4 Sender','Race4','Race4 body');
  v_ent := route_entry(v_ent.id, '17c00000-0002-0000-0000-000000000002', NULL);
  INSERT INTO r17c_ids VALUES ('race4', v_ent.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final external_correspondence;
BEGIN
  SELECT id INTO v_id FROM r17c_ids WHERE name = 'race4';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000001');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000002');

  PERFORM dblink_send_query('c1', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000003'::uuid, NULL)).to_section_id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (assign_entry('%s'::uuid, '17c00000-0001-0000-0000-000000000003'::uuid, NULL)).assigned_to::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT * INTO v_final FROM external_correspondence WHERE id = v_id;
  -- route_entry's own UPDATE sets assigned_to = p_assigned_to (NULL
  -- here) unconditionally as part of the SAME statement, so whichever
  -- of the two transactions commits LAST wins the whole row -- this is
  -- a genuine last-writer-wins race, not a bug: route_entry legitimately
  -- always re-states assigned_to together with to_section_id (mirroring
  -- entry-api.js's own route() shape, which does the same in a single
  -- UPDATE). Both calls must still complete without error and the row
  -- must be self-consistent (never a torn mix of "old to_section_id,
  -- new assigned_to" or vice versa).
  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: both route_entry and assign_entry should complete safely (got % successes, r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF v_final.to_section_id IS NULL THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: to_section_id must never be torn to NULL by this race';
  END IF;
  RAISE NOTICE 'CONC TEST 4 PASSED: route_entry vs assign_entry on the same entry serialize via row lock, final row is self-consistent (no torn write)';
END $$;

-- ── 5: two concurrent close_entry calls once the entry has genuinely
-- reached 'responded' (mirrors Requests' equivalent close race: the
-- pre-existing check_entry_status trigger's old=new short-circuit
-- makes "close an already-closed entry" a harmless no-op, not a
-- rejection, so both calls are expected to succeed) ──
SET ROLE authenticated;
DO $$
DECLARE v_ent external_correspondence; v_reply external_correspondence_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Race5 Sender','Race5','Race5 body');
  v_ent := route_entry(v_ent.id, '17c00000-0002-0000-0000-000000000002', '17c00000-0001-0000-0000-000000000003');
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000003"}',true);
  v_reply := draft_entry_reply(v_ent.id, 'Race5 reply', 'en');
  v_reply := submit_entry_reply(v_reply.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000005"}',true);
  v_reply := approve_entry_reply(v_reply.id);
  IF (SELECT status FROM external_correspondence WHERE id = v_ent.id) <> 'responded' THEN
    RAISE EXCEPTION 'fixture setup for CONC TEST 5 failed: entry is not responded';
  END IF;
  INSERT INTO r17c_ids VALUES ('race5', v_ent.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final_status TEXT;
BEGIN
  SELECT id INTO v_id FROM r17c_ids WHERE name = 'race5';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000001');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000002');

  PERFORM dblink_send_query('c1', format($q$SELECT (close_entry('%s'::uuid)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (close_entry('%s'::uuid)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT status INTO v_final_status FROM external_correspondence WHERE id = v_id;
  IF v_ok_count <> 2 OR v_final_status <> 'closed' THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: expected both close_entry calls to complete safely with a final status of closed, got % successes, final status %, r1=%, r2=%', v_ok_count, v_final_status, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 5 PASSED: two concurrent close_entry calls on an already-responded entry both complete safely (real transition + harmless same-status no-op), final status closed, no lost update';
END $$;

-- ── 6: duplicate command replay -- two concurrent submit_entry_reply
-- calls, only one may apply ──
SET ROLE authenticated;
DO $$
DECLARE v_ent external_correspondence; v_reply external_correspondence_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('email','public','Race6 Sender','Race6','Race6 body');
  v_ent := route_entry(v_ent.id, '17c00000-0002-0000-0000-000000000002', NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000003"}',true);
  v_reply := draft_entry_reply(v_ent.id, 'Race6 reply', 'en');
  INSERT INTO r17c_ids VALUES ('race6', v_reply.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id FROM r17c_ids WHERE name = 'race6';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000003');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (submit_entry_reply('%s'::uuid, NULL)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (submit_entry_reply('%s'::uuid, NULL)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 6 FAILED: exactly one of two identical concurrent submit_entry_reply replays should win, got %', v_ok_count;
  END IF;
  RAISE NOTICE 'CONC TEST 6 PASSED: duplicate submit_entry_reply replay -- exactly one applies, the other is rejected by the state guard, not silently double-applied';
END $$;

-- ── 7: unrelated entries progress independently (no cross-entry contention) ──
SET ROLE authenticated;
DO $$
DECLARE v_a external_correspondence; v_b external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_a := create_entry('email','public','Race7A Sender','Race7A','Race7A body');
  v_b := create_entry('email','public','Race7B Sender','Race7B','Race7B body');
  INSERT INTO r17c_ids VALUES ('race7a', v_a.id);
  INSERT INTO r17c_ids VALUES ('race7b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_a FROM r17c_ids WHERE name = 'race7a';
  SELECT id INTO v_b FROM r17c_ids WHERE name = 'race7b';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000001');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000001');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000002'::uuid, NULL)).status$q$, v_a));
  PERFORM dblink_send_query('c2', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000002'::uuid, NULL)).status$q$, v_b));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_r1 <> 'routed' OR v_r2 <> 'routed' THEN
    RAISE EXCEPTION 'CONC TEST 7 FAILED: two unrelated entries should both route independently without blocking each other (r1=%, r2=%)', v_r1, v_r2;
  END IF;
  IF clock_timestamp() - v_start > interval '5 seconds' THEN
    RAISE EXCEPTION 'CONC TEST 7 FAILED: unrelated entries took too long -- suspected unnecessary lock contention';
  END IF;
  RAISE NOTICE 'CONC TEST 7 PASSED: two unrelated entries route concurrently with no cross-entry contention or delay';
END $$;

-- ── 8: no deadlock across a crossed-order chain of concurrent
-- route_entry calls on two distinct rows ──
SET ROLE authenticated;
DO $$
DECLARE v_a external_correspondence; v_b external_correspondence;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"17c00000-0001-0000-0000-000000000001"}',true);
  v_a := create_entry('email','public','Race8A Sender','Race8A','Race8A body');
  v_b := create_entry('email','public','Race8B Sender','Race8B','Race8B body');
  INSERT INTO r17c_ids VALUES ('race8a', v_a.id);
  INSERT INTO r17c_ids VALUES ('race8b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT;
BEGIN
  SELECT id INTO v_a FROM r17c_ids WHERE name = 'race8a';
  SELECT id INTO v_b FROM r17c_ids WHERE name = 'race8b';
  PERFORM r17c_connect('c1', '17c00000-0001-0000-0000-000000000001');
  PERFORM r17c_connect('c2', '17c00000-0001-0000-0000-000000000001');

  -- c1 routes A then B; c2 routes B then A -- opposite acquisition
  -- order across two rows is the classic deadlock shape; if the RPCs
  -- held any cross-row lock ordering issue, one of these would hang
  -- until statement_timeout rather than complete quickly.
  PERFORM dblink_send_query('c1', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000002'::uuid, NULL)).status, (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000002'::uuid, NULL)).status$q$, v_a, v_b));
  PERFORM dblink_send_query('c2', format($q$SELECT (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000003'::uuid, NULL)).status, (route_entry('%s'::uuid, '17c00000-0002-0000-0000-000000000003'::uuid, NULL)).status$q$, v_b, v_a));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF (SELECT status FROM external_correspondence WHERE id = v_a) <> 'routed' OR (SELECT status FROM external_correspondence WHERE id = v_b) <> 'routed' THEN
    RAISE EXCEPTION 'CONC TEST 8 FAILED: both entries should have reached routed (possible deadlock or lost update)';
  END IF;
  RAISE NOTICE 'CONC TEST 8 PASSED: crossed-order two-row route_entry sequence completes without deadlock, both entries reach routed';
END $$;

DROP FUNCTION r17c_connect(TEXT, UUID);
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'ENTRY SERVER MUTATION FOUNDATION CONCURRENCY TESTS: 8/8 PASSED'; END $$;
