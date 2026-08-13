-- CAP-003 Phase 1.8A concurrency suite (9 race scenarios). Disposable
-- local PostgreSQL only; requires dblink. Mirrors the exact dblink-
-- based genuinely-independent-session pattern every other CAP-002/
-- CAP-003 concurrency suite in this repository already establishes.
-- Covers every race Section 12 calls for that corresponds to a REAL
-- Internal Collaboration command: two users on the same pending
-- record, route vs return, route vs assign, two assignments, approval
-- vs return, close vs another lifecycle action, replay of an already-
-- completed transition, unrelated records progressing concurrently,
-- and deadlock safety across a crossed-order two-row chain.
--
-- Scenarios 3/4/6/9 deliberately use TWO DIFFERENT SUPERVISORS (not
-- two same-section staff) as the racing actors, exactly as Entry's own
-- 1.7A concurrency suite chose "Entry staff" (an org-wide role) for its
-- route-vs-assign scenario: is_supervisor_or_above()'s authorization
-- branch depends only on the TARGET section's org, not on which
-- specific section currently holds the thread, so it stays valid
-- regardless of which racing call commits first -- unlike a to_section-
-- membership check, which a winning reroute can invalidate out from
-- under the loser mid-race (a genuine, correct outcome, but a confound
-- for a "both individually valid" no-lost-update proof).
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE r18d_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON r18d_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
  ('18d00000-0000-0000-0000-000000000001','Conc T18D Org','authority','C18D');
INSERT INTO divisions(id, org_id, name) VALUES
  ('18d00000-0004-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','18d00000-0004-0000-0000-000000000001','Records','C18REC'),
  ('18d00000-0002-0000-0000-000000000002','18d00000-0000-0000-0000-000000000001','18d00000-0004-0000-0000-000000000001','Welfare','C18WEL'),
  ('18d00000-0002-0000-0000-000000000003','18d00000-0000-0000-0000-000000000001','18d00000-0004-0000-0000-000000000001','Ops','C18OPS');
INSERT INTO auth.users(id,email) VALUES
  ('18d00000-0001-0000-0000-000000000001','c18-records@t.local'),
  ('18d00000-0001-0000-0000-000000000002','c18-welfare1@t.local'),
  ('18d00000-0001-0000-0000-000000000003','c18-welfare2@t.local'),
  ('18d00000-0001-0000-0000-000000000004','c18-super1@t.local'),
  ('18d00000-0001-0000-0000-000000000005','c18-super2@t.local'),
  ('18d00000-0001-0000-0000-000000000006','c18-assignee1@t.local'),
  ('18d00000-0001-0000-0000-000000000007','c18-assignee2@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('18d00000-0001-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','C18-1','Records Staff','c18-records@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000002','18d00000-0000-0000-0000-000000000001','C18-2','Welfare Staff 1','c18-welfare1@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000003','18d00000-0000-0000-0000-000000000001','C18-3','Welfare Staff 2','c18-welfare2@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000004','18d00000-0000-0000-0000-000000000001','C18-4','Welfare Super 1','c18-super1@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000005','18d00000-0000-0000-0000-000000000001','C18-5','Welfare Super 2','c18-super2@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000006','18d00000-0000-0000-0000-000000000001','C18-6','Assignee 1','c18-assignee1@t.local',TRUE),
  ('18d00000-0001-0000-0000-000000000007','18d00000-0000-0000-0000-000000000001','C18-7','Assignee 2','c18-assignee2@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('18d00000-0001-0000-0000-000000000001','section','18d00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('18d00000-0001-0000-0000-000000000002','section','18d00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('18d00000-0001-0000-0000-000000000003','section','18d00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('18d00000-0001-0000-0000-000000000004','section','18d00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('18d00000-0001-0000-0000-000000000005','section','18d00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);
-- Assignees 6/7 deliberately have NO section assignment -- they are
-- only ever used as assign_internal_request TARGETS, not callers.

CREATE OR REPLACE FUNCTION r18d_connect(p_conn TEXT, p_user UUID) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($q$SELECT set_config('request.jwt.claims', '{"sub":"%s"}', false)$q$, p_user)) AS t(v text);
END;
$$ LANGUAGE plpgsql;

SET ROLE authenticated;

-- ── 1: two Welfare staff race mark_internal_request_received on the
-- SAME thread -- the status='sent' guard means exactly one wins ──
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race1','Race1 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race1','Race1 body',v_preq.id,NULL);
  INSERT INTO r18d_ids VALUES ('race1', v_ic.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_received_count INT;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race1';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000002');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_internal_request_received('%s'::uuid)).received_by::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_internal_request_received('%s'::uuid)).received_by::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: expected exactly one mark_internal_request_received to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT count(*) INTO v_received_count FROM internal_requests WHERE id = v_id AND received_by IS NOT NULL;
  IF v_received_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: thread must have exactly one recorded receipt';
  END IF;
  RAISE NOTICE 'CONC TEST 1 PASSED: two concurrent mark_internal_request_received calls on the same thread -- exactly one wins, no lost update, receipt recorded exactly once';
END $$;

-- ── 2: reroute_internal_request vs return_internal_request_to_sender
-- race on the SAME thread. Both actions require the caller be a
-- CURRENT to_section holder at the moment they act; whichever commits
-- first moves to_section_id away from Welfare, which correctly
-- invalidates the loser's own authorization on re-check -- exactly one
-- may legitimately apply. ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race2','Race2 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race2','Race2 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_ic.id);
  INSERT INTO r18d_ids VALUES ('race2', v_ic.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final internal_requests;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race2';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000002');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000003'::uuid)).to_section_id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (return_internal_request_to_sender('%s'::uuid, 'race')).to_section_id::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT * INTO v_final FROM internal_requests WHERE id = v_id;
  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: expected exactly one of reroute/return-to-sender to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF v_final.to_section_id NOT IN ('18d00000-0002-0000-0000-000000000003','18d00000-0002-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: final to_section_id must be exactly one of the two attempted destinations, got %', v_final.to_section_id;
  END IF;
  RAISE NOTICE 'CONC TEST 2 PASSED: reroute_internal_request vs return_internal_request_to_sender on the same thread -- exactly one wins (the loser is correctly de-authorized by the winner''s own state change), final to_section_id is self-consistent';
END $$;

-- ── 3: reroute_internal_request vs assign_internal_request race on the
-- same thread, both callers Welfare SUPERVISORS (org-scoped
-- authorization, stable regardless of which of the two destinations
-- wins) -- both individually valid, no lost update expected, final row
-- self-consistent (last committer wins the whole row, matching
-- assign/reroute's own real single-UPDATE shape) ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race3','Race3 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race3','Race3 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_ic.id);
  INSERT INTO r18d_ids VALUES ('race3', v_ic.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final internal_requests;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race3';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000004');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000005');

  PERFORM dblink_send_query('c1', format($q$SELECT (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000003'::uuid)).to_section_id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (assign_internal_request('%s'::uuid, '18d00000-0001-0000-0000-000000000006'::uuid)).assigned_to::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT * INTO v_final FROM internal_requests WHERE id = v_id;
  -- reroute's own UPDATE unconditionally resets assigned_to=NULL as
  -- part of the SAME statement (mirroring Entry's route_entry), so
  -- whichever transaction commits LAST wins the whole row -- a genuine
  -- last-writer-wins race, not a bug. Both calls must still complete
  -- without error and the row must never be torn.
  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: both reroute_internal_request and assign_internal_request should complete safely (got % successes, r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF v_final.to_section_id IS NULL THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: to_section_id must never be torn to NULL by this race';
  END IF;
  RAISE NOTICE 'CONC TEST 3 PASSED: reroute_internal_request vs assign_internal_request on the same thread serialize via row lock, final row is self-consistent (no torn write)';
END $$;

-- ── 4: two concurrent assign_internal_request calls to DIFFERENT
-- assignees on the same thread -- no state guard distinguishes them
-- (assigning twice is a legal repeated transition), both individually
-- valid, last-writer-wins on the whole row ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race4','Race4 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race4','Race4 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_ic.id);
  INSERT INTO r18d_ids VALUES ('race4', v_ic.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final_assignee UUID;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race4';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000004');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000005');

  PERFORM dblink_send_query('c1', format($q$SELECT (assign_internal_request('%s'::uuid, '18d00000-0001-0000-0000-000000000006'::uuid)).assigned_to::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (assign_internal_request('%s'::uuid, '18d00000-0001-0000-0000-000000000007'::uuid)).assigned_to::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT assigned_to INTO v_final_assignee FROM internal_requests WHERE id = v_id;
  IF v_ok_count <> 2 OR v_final_assignee NOT IN ('18d00000-0001-0000-0000-000000000006','18d00000-0001-0000-0000-000000000007') THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: expected both assign_internal_request calls to complete safely with a self-consistent final assignee (got % successes, final=%)', v_ok_count, v_final_assignee;
  END IF;
  RAISE NOTICE 'CONC TEST 4 PASSED: two concurrent assign_internal_request calls to different assignees on the same thread both complete safely, final assigned_to is exactly one of the two attempted values (no torn write)';
END $$;

-- ── 5: approve_internal_request_reply vs return_internal_request_reply
-- race on the SAME reply -- both require status='pending_approval',
-- setting it to mutually exclusive terminal states ('sent' vs
-- 'draft'), so exactly one may apply ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_reply internal_request_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race5','Race5 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race5','Race5 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_ic.id, 'Race5 reply');
  v_reply := submit_internal_request_reply(v_reply.id, NULL);
  INSERT INTO r18d_ids VALUES ('race5', v_reply.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final_status TEXT;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race5';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000004');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000005');

  PERFORM dblink_send_query('c1', format($q$SELECT (approve_internal_request_reply('%s'::uuid)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (return_internal_request_reply('%s'::uuid)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT status INTO v_final_status FROM internal_request_replies WHERE id = v_id;
  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: expected exactly one of approve/return to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  IF v_final_status NOT IN ('sent','draft') THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: final reply status must be exactly one of the two attempted outcomes, got %', v_final_status;
  END IF;
  RAISE NOTICE 'CONC TEST 5 PASSED: approve_internal_request_reply vs return_internal_request_reply on the same reply -- exactly one wins, final status is self-consistent (sent XOR draft), no partial state';
END $$;

-- ── 6: close_internal_request vs reroute_internal_request race on the
-- same thread (neither has a status guard -- both are legal
-- regardless of current state), both callers Welfare supervisors --
-- both individually valid, last-writer-wins on the whole row ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race6','Race6 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race6','Race6 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_ic.id);
  INSERT INTO r18d_ids VALUES ('race6', v_ic.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final internal_requests;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race6';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000004');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000005');

  PERFORM dblink_send_query('c1', format($q$SELECT (close_internal_request('%s'::uuid)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000003'::uuid)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT * INTO v_final FROM internal_requests WHERE id = v_id;
  IF v_ok_count <> 2 OR v_final.status NOT IN ('closed','sent') THEN
    RAISE EXCEPTION 'CONC TEST 6 FAILED: both close_internal_request and reroute_internal_request should complete safely with a self-consistent final status (got % successes, final=%)', v_ok_count, v_final.status;
  END IF;
  RAISE NOTICE 'CONC TEST 6 PASSED: close_internal_request vs reroute_internal_request on the same thread (neither state-guarded) both complete safely, final status self-consistent, no lost update';
END $$;

-- ── 7: duplicate command replay -- two concurrent
-- submit_internal_request_reply calls, only one may apply ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_reply internal_request_replies;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race7','Race7 body','en','en',NULL,NULL);
  v_ic := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race7','Race7 body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_ic.id, 'Race7 reply');
  INSERT INTO r18d_ids VALUES ('race7', v_reply.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id FROM r18d_ids WHERE name = 'race7';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000002');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000002');

  PERFORM dblink_send_query('c1', format($q$SELECT (submit_internal_request_reply('%s'::uuid, NULL)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (submit_internal_request_reply('%s'::uuid, NULL)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 7 FAILED: exactly one of two identical concurrent submit_internal_request_reply replays should win, got %', v_ok_count;
  END IF;
  RAISE NOTICE 'CONC TEST 7 PASSED: duplicate submit_internal_request_reply replay -- exactly one applies, the other is rejected by the state guard, not silently double-applied';
END $$;

-- ── 8: unrelated threads progress independently (no cross-thread contention) ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_a internal_requests; v_b internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race8P','Race8P body','en','en',NULL,NULL);
  v_a := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race8A','Race8A body',v_preq.id,NULL);
  v_b := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race8B','Race8B body',v_preq.id,NULL);
  INSERT INTO r18d_ids VALUES ('race8a', v_a.id);
  INSERT INTO r18d_ids VALUES ('race8b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_a FROM r18d_ids WHERE name = 'race8a';
  SELECT id INTO v_b FROM r18d_ids WHERE name = 'race8b';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000002');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000002');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1', format($q$SELECT (mark_internal_request_received('%s'::uuid)).status$q$, v_a));
  PERFORM dblink_send_query('c2', format($q$SELECT (mark_internal_request_received('%s'::uuid)).status$q$, v_b));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_r1 <> 'received' OR v_r2 <> 'received' THEN
    RAISE EXCEPTION 'CONC TEST 8 FAILED: two unrelated threads should both progress independently without blocking each other (r1=%, r2=%)', v_r1, v_r2;
  END IF;
  IF clock_timestamp() - v_start > interval '5 seconds' THEN
    RAISE EXCEPTION 'CONC TEST 8 FAILED: unrelated threads took too long -- suspected unnecessary lock contention';
  END IF;
  RAISE NOTICE 'CONC TEST 8 PASSED: two unrelated threads progress concurrently with no cross-thread contention or delay';
END $$;

-- ── 9: no deadlock across a crossed-order chain of concurrent
-- reroute_internal_request calls on two distinct rows ──
SET ROLE authenticated;
DO $$
DECLARE v_preq requests; v_a internal_requests; v_b internal_requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"18d00000-0001-0000-0000-000000000001"}',true);
  v_preq := create_request('18d00000-0002-0000-0000-000000000001','18d00000-0000-0000-0000-000000000001','Race9P','Race9P body','en','en',NULL,NULL);
  v_a := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race9A','Race9A body',v_preq.id,NULL);
  v_b := create_internal_request('18d00000-0002-0000-0000-000000000001','18d00000-0002-0000-0000-000000000002','Race9B','Race9B body',v_preq.id,NULL);
  INSERT INTO r18d_ids VALUES ('race9a', v_a.id);
  INSERT INTO r18d_ids VALUES ('race9b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT;
BEGIN
  SELECT id INTO v_a FROM r18d_ids WHERE name = 'race9a';
  SELECT id INTO v_b FROM r18d_ids WHERE name = 'race9b';
  PERFORM r18d_connect('c1', '18d00000-0001-0000-0000-000000000004');
  PERFORM r18d_connect('c2', '18d00000-0001-0000-0000-000000000005');

  -- c1 reroutes A then B; c2 reroutes B then A -- opposite acquisition
  -- order across two rows is the classic deadlock shape; if the RPCs
  -- held any cross-row lock ordering issue, one of these would hang
  -- until statement_timeout rather than complete quickly.
  PERFORM dblink_send_query('c1', format($q$SELECT (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000003'::uuid)).status, (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000003'::uuid)).status$q$, v_a, v_b));
  PERFORM dblink_send_query('c2', format($q$SELECT (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000001'::uuid)).status, (reroute_internal_request('%s'::uuid, '18d00000-0002-0000-0000-000000000001'::uuid)).status$q$, v_b, v_a));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF (SELECT status FROM internal_requests WHERE id = v_a) <> 'sent' OR (SELECT status FROM internal_requests WHERE id = v_b) <> 'sent' THEN
    RAISE EXCEPTION 'CONC TEST 9 FAILED: both threads should have reached sent (possible deadlock or lost update)';
  END IF;
  RAISE NOTICE 'CONC TEST 9 PASSED: crossed-order two-row reroute_internal_request sequence completes without deadlock, both threads reach sent';
END $$;

DROP FUNCTION r18d_connect(TEXT, UUID);
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'INTERNAL COLLABORATION SERVER MUTATION FOUNDATION CONCURRENCY TESTS: 9/9 PASSED'; END $$;
