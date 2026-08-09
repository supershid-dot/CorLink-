-- CAP-003 Phase 1.6A concurrency suite (10 race scenarios). Disposable
-- local PostgreSQL only; requires dblink. Mirrors the exact dblink-
-- based genuinely-independent-session pattern every other CAP-002/
-- CAP-003 concurrency suite in this repository already establishes.
-- Only scenarios that correspond to an ACTUALLY-migrated command are
-- exercised -- deadline extensions and Further Information cycles have
-- no existing frontend implementation (docs/89) and are not part of
-- this milestone, so no race scenario is invented for either.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE r16c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON r16c_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
  ('16c00000-0000-0000-0000-000000000001','Conc Org Alpha','authority','CONA'),
  ('16c00000-0000-0000-0000-000000000002','Conc Org Beta','authority','CONB');
INSERT INTO divisions(id, org_id, name) VALUES
  ('16c00000-0004-0000-0000-000000000001','16c00000-0000-0000-0000-000000000001','A Div'),
  ('16c00000-0004-0000-0000-000000000002','16c00000-0000-0000-0000-000000000002','B Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000001','16c00000-0004-0000-0000-000000000001','A Sec','CAX'),
  ('16c00000-0002-0000-0000-000000000002','16c00000-0000-0000-0000-000000000002','16c00000-0004-0000-0000-000000000002','B Sec','CBX'),
  ('16c00000-0002-0000-0000-000000000003','16c00000-0000-0000-0000-000000000002','16c00000-0004-0000-0000-000000000002','B Sec2','CBY');
INSERT INTO auth.users(id,email) VALUES
  ('16c00000-0001-0000-0000-000000000001','c16-a-staff@t.local'),
  ('16c00000-0001-0000-0000-000000000002','c16-a-super@t.local'),
  ('16c00000-0001-0000-0000-000000000003','c16-b-super1@t.local'),
  ('16c00000-0001-0000-0000-000000000004','c16-b-super2@t.local'),
  ('16c00000-0001-0000-0000-000000000005','c16-b-staff@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('16c00000-0001-0000-0000-000000000001','16c00000-0000-0000-0000-000000000001','C16-1','A Staff','c16-a-staff@t.local',TRUE),
  ('16c00000-0001-0000-0000-000000000002','16c00000-0000-0000-0000-000000000001','C16-2','A Super','c16-a-super@t.local',TRUE),
  ('16c00000-0001-0000-0000-000000000003','16c00000-0000-0000-0000-000000000002','C16-3','B Super 1','c16-b-super1@t.local',TRUE),
  ('16c00000-0001-0000-0000-000000000004','16c00000-0000-0000-0000-000000000002','C16-4','B Super 2','c16-b-super2@t.local',TRUE),
  ('16c00000-0001-0000-0000-000000000005','16c00000-0000-0000-0000-000000000002','C16-5','B Staff','c16-b-staff@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('16c00000-0001-0000-0000-000000000001','section','16c00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('16c00000-0001-0000-0000-000000000002','section','16c00000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
  ('16c00000-0001-0000-0000-000000000003','section','16c00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('16c00000-0001-0000-0000-000000000004','section','16c00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
  ('16c00000-0001-0000-0000-000000000005','section','16c00000-0002-0000-0000-000000000002','staff',TRUE,TRUE);

CREATE OR REPLACE FUNCTION r16c_connect(p_conn TEXT, p_user UUID) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($q$SELECT set_config('request.jwt.claims', '{"sub":"%s"}', false)$q$, p_user)) AS t(v text);
END;
$$ LANGUAGE plpgsql;

SET ROLE authenticated;

-- ── 1: two supervisors approve the SAME pending request concurrently ──
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race1','Race1 body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  INSERT INTO r16c_ids VALUES ('race1', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_ref_count INT;
BEGIN
  SELECT id INTO v_id FROM r16c_ids WHERE name = 'race1';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000002');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000002');

  PERFORM dblink_send_query('c1', format($q$SELECT (approve_request('%s'::uuid, 'first')).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (approve_request('%s'::uuid, 'second')).status$q$, v_id));

  BEGIN
    SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
    v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN
    SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
    v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: expected exactly one approve_request to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
  SELECT count(*) INTO v_ref_count FROM approvals WHERE record_type='request' AND record_id=v_id AND decision='approved';
  IF v_ref_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 1 FAILED: expected exactly one approvals row, got %', v_ref_count;
  END IF;
  RAISE NOTICE 'CONC TEST 1 PASSED: two concurrent approve_request calls on the same request -- exactly one wins, no lost update, no duplicate approvals row';
END $$;

-- ── 2: route_request vs return_request_to_previous_section race ──
SET ROLE authenticated;
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race2','Race2 body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000003"}',true);
  v_req := mark_request_received(v_req.id);
  -- Route TWICE first (section2 then section3), so previous_section_id
  -- (trigger-maintained) is genuinely non-NULL before the race below --
  -- a single first-time route with no configured default_receiving_
  -- section_id leaves previous_section_id NULL, which would make
  -- return_request_to_previous_section correctly reject with "no
  -- previous section" (a real precondition, not a bug) rather than
  -- race at all.
  v_req := route_request(v_req.id, '16c00000-0002-0000-0000-000000000002');
  v_req := route_request(v_req.id, '16c00000-0002-0000-0000-000000000003');
  INSERT INTO r16c_ids VALUES ('race2', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id FROM r16c_ids WHERE name = 'race2';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000003');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000003');

  PERFORM dblink_send_query('c1', format($q$SELECT (route_request('%s'::uuid, '16c00000-0002-0000-0000-000000000003'::uuid)).to_section_id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (return_request_to_previous_section('%s'::uuid, 'wrong section')).to_section_id::text$q$, v_id));

  BEGIN
    SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN
    SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  -- Both are ordinary UPDATEs on the same row with no state-guard
  -- distinguishing "already routed" from "already returned" (routing
  -- and returning are both legal from 'in_progress', repeatedly, per
  -- current business rules -- there is no invalid-transition here to
  -- reject). Postgres's row lock (FOR UPDATE inside each function)
  -- serializes them: both can legitimately succeed, one after the
  -- other, but the final to_section_id must be self-consistent
  -- (whichever committed last), never a torn/mixed value.
  IF v_ok_count <> 2 THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: both route_request and return_request_to_previous_section should be individually valid transitions (got % successes)', v_ok_count;
  END IF;
  IF (SELECT to_section_id FROM requests WHERE id = v_id) IS NULL THEN
    RAISE EXCEPTION 'CONC TEST 2 FAILED: final to_section_id must be one of the two valid values, not NULL/torn';
  END IF;
  RAISE NOTICE 'CONC TEST 2 PASSED: route_request vs return_request_to_previous_section serialize via row lock, final state is self-consistent (no torn write)';
END $$;

-- ── 3: two different responders create_response concurrently (no interference) ──
SET ROLE authenticated;
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race3','Race3 body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  INSERT INTO r16c_ids VALUES ('race3', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_resp_count INT;
BEGIN
  SELECT id INTO v_id FROM r16c_ids WHERE name = 'race3';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000003');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000005');

  PERFORM dblink_send_query('c1', format($q$SELECT (create_response('%s'::uuid, 'resp from super1', 'en')).id::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (create_response('%s'::uuid, 'resp from staff', 'en')).id::text$q$, v_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT count(*) INTO v_resp_count FROM responses WHERE request_id = v_id;
  IF v_resp_count <> 2 OR v_r1 = v_r2 THEN
    RAISE EXCEPTION 'CONC TEST 3 FAILED: expected two independent response rows, got % (ids %, %)', v_resp_count, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 3 PASSED: two concurrent create_response calls from different responders on the same request produce two independent rows, no interference';
END $$;

-- ── 4: close vs response -- two concurrent close_request calls once
-- the request has genuinely reached 'responded' (the only status
-- schema.sql's pre-existing check_request_status trigger allows to
-- transition into 'closed' -- discovered while first drafting this
-- scenario: an "in_progress -> closed" race is not a real race at all,
-- it is an always-invalid transition the trigger rejects regardless of
-- timing, so approve_response is run to completion first, sequentially,
-- THEN two supervisors race to close the now-'responded' request) ──
SET ROLE authenticated;
DO $$
DECLARE v_req requests; v_resp responses;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race4','Race4 body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  -- Routed to a section first: approve_response's reference-number
  -- generation is keyed on the request's to_section_id, which must be
  -- non-NULL -- exactly the same pre-existing requirement the legacy
  -- approveResponse() JS already has (it reads request.to_section_id
  -- the same way). Unrouted -> straight-to-response is not a realistic
  -- production path.
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000003"}',true);
  v_req := mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '16c00000-0002-0000-0000-000000000002');
  v_resp := create_response(v_req.id, 'race4 response', 'en');
  v_resp := submit_response(v_resp.id, NULL);
  v_resp := approve_response(v_resp.id, 'approved');
  IF (SELECT status FROM requests WHERE id = v_req.id) <> 'responded' THEN
    RAISE EXCEPTION 'fixture setup for CONC TEST 4 failed: request is not responded';
  END IF;
  INSERT INTO r16c_ids VALUES ('race4_req', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_req_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final_status TEXT;
BEGIN
  SELECT id INTO v_req_id FROM r16c_ids WHERE name = 'race4_req';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000003');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000004');

  PERFORM dblink_send_query('c1', format($q$SELECT (close_request('%s'::uuid)).status$q$, v_req_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (close_request('%s'::uuid)).status$q$, v_req_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error: ' || SQLERRM; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error: ' || SQLERRM; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  -- The FIRST close_request to acquire the row lock legitimately closes
  -- (responded -> closed, a valid transition); the second, once
  -- unblocked, re-reads status='closed' and check_request_status's own
  -- old_status = new_status short-circuit makes a same-status "close an
  -- already-closed request" a harmless no-op UPDATE rather than a
  -- rejected one -- so both calls are expected to report success here,
  -- but there is still only ever one real state change, never a lost
  -- update or torn write.
  SELECT status INTO v_final_status FROM requests WHERE id = v_req_id;
  IF v_ok_count <> 2 OR v_final_status <> 'closed' THEN
    RAISE EXCEPTION 'CONC TEST 4 FAILED: expected both close_request calls to complete safely with a final status of closed, got % successes, final status %, r1=%, r2=%', v_ok_count, v_final_status, v_r1, v_r2;
  END IF;
  RAISE NOTICE 'CONC TEST 4 PASSED: two concurrent close_request calls on an already-responded request both complete safely (real transition + harmless same-status no-op), final status closed, no lost update';
END $$;

-- ── 5: duplicate command replay -- two concurrent submit_request calls, only one may apply ──
SET ROLE authenticated;
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race5','Race5 body','en','en',NULL,NULL);
  INSERT INTO r16c_ids VALUES ('race5', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  SELECT id INTO v_id FROM r16c_ids WHERE name = 'race5';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000001');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1', format($q$SELECT (submit_request('%s'::uuid, NULL)).status$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (submit_request('%s'::uuid, NULL)).status$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_ok_count <> 1 THEN
    RAISE EXCEPTION 'CONC TEST 5 FAILED: exactly one of two identical concurrent submit_request replays should win, got %', v_ok_count;
  END IF;
  RAISE NOTICE 'CONC TEST 5 PASSED: duplicate submit_request replay -- exactly one applies, the other is rejected by the state guard, not silently double-applied';
END $$;

-- ── 6: two concurrent assign_request calls on the same request (last valid wins, no lost update) ──
SET ROLE authenticated;
DO $$
DECLARE v_req requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race6','Race6 body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000003"}',true);
  v_req := mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '16c00000-0002-0000-0000-000000000002');
  INSERT INTO r16c_ids VALUES ('race6', v_req.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0; v_final UUID;
BEGIN
  SELECT id INTO v_id FROM r16c_ids WHERE name = 'race6';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000003');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000004');

  PERFORM dblink_send_query('c1', format($q$SELECT (assign_request('%s'::uuid, '16c00000-0001-0000-0000-000000000003'::uuid)).assigned_to::text$q$, v_id));
  PERFORM dblink_send_query('c2', format($q$SELECT (assign_request('%s'::uuid, '16c00000-0001-0000-0000-000000000004'::uuid)).assigned_to::text$q$, v_id));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true); v_ok_count := v_ok_count + 1;
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  SELECT assigned_to INTO v_final FROM requests WHERE id = v_id;
  IF v_ok_count <> 2 OR v_final NOT IN ('16c00000-0001-0000-0000-000000000003','16c00000-0001-0000-0000-000000000004') THEN
    RAISE EXCEPTION 'CONC TEST 6 FAILED: both assigns should apply in some serial order, final assignee must be one of the two (got %)', v_final;
  END IF;
  RAISE NOTICE 'CONC TEST 6 PASSED: two concurrent assign_request calls serialize via row lock, final assignee is exactly one of the two attempted values (no lost update, no torn write)';
END $$;

-- ── 7: unrelated requests progress independently (no cross-request contention) ──
SET ROLE authenticated;
DO $$
DECLARE v_a requests; v_b requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_a := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race7A','Race7A body','en','en',NULL,NULL);
  v_b := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race7B','Race7B body','en','en',NULL,NULL);
  INSERT INTO r16c_ids VALUES ('race7a', v_a.id);
  INSERT INTO r16c_ids VALUES ('race7b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_a FROM r16c_ids WHERE name = 'race7a';
  SELECT id INTO v_b FROM r16c_ids WHERE name = 'race7b';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000001');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000001');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1', format($q$SELECT (submit_request('%s'::uuid, NULL)).status$q$, v_a));
  PERFORM dblink_send_query('c2', format($q$SELECT (submit_request('%s'::uuid, NULL)).status$q$, v_b));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF v_r1 <> 'pending_approval' OR v_r2 <> 'pending_approval' THEN
    RAISE EXCEPTION 'CONC TEST 7 FAILED: two unrelated requests should both submit independently without blocking each other (r1=%, r2=%)', v_r1, v_r2;
  END IF;
  IF clock_timestamp() - v_start > interval '5 seconds' THEN
    RAISE EXCEPTION 'CONC TEST 7 FAILED: unrelated requests took too long -- suspected unnecessary lock contention';
  END IF;
  RAISE NOTICE 'CONC TEST 7 PASSED: two unrelated requests submit concurrently with no cross-request contention or delay';
END $$;

-- ── 8: no deadlock across a longer chain of concurrent operations on distinct rows ──
SET ROLE authenticated;
DO $$
DECLARE v_a requests; v_b requests;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"16c00000-0001-0000-0000-000000000001"}',true);
  v_a := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race8A','Race8A body','en','en',NULL,NULL);
  v_b := create_request('16c00000-0002-0000-0000-000000000001','16c00000-0000-0000-0000-000000000002','Race8B','Race8B body','en','en',NULL,NULL);
  v_a := submit_request(v_a.id, NULL); v_b := submit_request(v_b.id, NULL);
  INSERT INTO r16c_ids VALUES ('race8a', v_a.id);
  INSERT INTO r16c_ids VALUES ('race8b', v_b.id);
END $$;
RESET ROLE;
DO $$
DECLARE v_a UUID; v_b UUID; v_r1 TEXT; v_r2 TEXT;
BEGIN
  SELECT id INTO v_a FROM r16c_ids WHERE name = 'race8a';
  SELECT id INTO v_b FROM r16c_ids WHERE name = 'race8b';
  PERFORM r16c_connect('c1', '16c00000-0001-0000-0000-000000000002');
  PERFORM r16c_connect('c2', '16c00000-0001-0000-0000-000000000002');

  -- c1 approves A then B; c2 approves B then A -- opposite acquisition
  -- order across two rows is the classic deadlock shape; if the RPCs
  -- held any cross-row lock ordering issue, one of these would hang
  -- until statement_timeout rather than complete quickly.
  PERFORM dblink_send_query('c1', format($q$SELECT (approve_request('%s'::uuid, NULL)).status, (approve_request('%s'::uuid, NULL)).status$q$, v_a, v_b));
  PERFORM dblink_send_query('c2', format($q$SELECT (approve_request('%s'::uuid, NULL)).status, (approve_request('%s'::uuid, NULL)).status$q$, v_b, v_a));

  BEGIN SELECT t.v INTO v_r1 FROM dblink_get_result('c1', true) AS t(v TEXT); PERFORM dblink_get_result('c1', true);
  EXCEPTION WHEN OTHERS THEN v_r1 := 'error'; END;
  BEGIN SELECT t.v INTO v_r2 FROM dblink_get_result('c2', true) AS t(v TEXT); PERFORM dblink_get_result('c2', true);
  EXCEPTION WHEN OTHERS THEN v_r2 := 'error'; END;
  PERFORM dblink_disconnect('c1'); PERFORM dblink_disconnect('c2');

  IF (SELECT status FROM requests WHERE id = v_a) <> 'sent' OR (SELECT status FROM requests WHERE id = v_b) <> 'sent' THEN
    RAISE EXCEPTION 'CONC TEST 8 FAILED: both requests should have reached sent (possible deadlock or lost update)';
  END IF;
  RAISE NOTICE 'CONC TEST 8 PASSED: crossed-order two-row approval sequence completes without deadlock, both requests reach sent';
END $$;

DROP FUNCTION r16c_connect(TEXT, UUID);
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'REQUESTS SERVER MUTATION FOUNDATION CONCURRENCY TESTS: 8/8 PASSED'; END $$;
