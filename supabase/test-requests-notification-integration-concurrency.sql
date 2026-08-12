-- CAP-003 Phase 1.6B notification event integration -- concurrency
-- suite. Disposable local PostgreSQL only, genuine multi-session via
-- dblink. Runs top-level (not wrapped in one transaction, since each
-- dblink connection is its own session); fixtures are explicitly
-- cleaned up at the end.
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TABLE IF NOT EXISTS r90c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT, DELETE ON r90c_results TO authenticated, service_role;
DELETE FROM r90c_results;

INSERT INTO organizations(id,name,type,code) VALUES
 ('90200000-0000-0000-0000-000000000001','R90C Org Alpha','authority','R90CA'),
 ('90200000-0000-0000-0000-000000000002','R90C Org Beta','authority','R90CB');
INSERT INTO divisions(id, org_id, name) VALUES
 ('90200000-0004-0000-0000-000000000001','90200000-0000-0000-0000-000000000001','R90C Alpha Div'),
 ('90200000-0004-0000-0000-000000000002','90200000-0000-0000-0000-000000000002','R90C Beta Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000001','90200000-0004-0000-0000-000000000001','R90C Alpha Sec A','R90CAA'),
 ('90200000-0002-0000-0000-000000000002','90200000-0000-0000-0000-000000000002','90200000-0004-0000-0000-000000000002','R90C Beta Sec A','R90CBA');
INSERT INTO auth.users(id,email) VALUES
 ('90200000-0001-0000-0000-000000000001','alpha-staff@r90ct.local'),
 ('90200000-0001-0000-0000-000000000002','alpha-super@r90ct.local'),
 ('90200000-0001-0000-0000-000000000003','beta-staff@r90ct.local'),
 ('90200000-0001-0000-0000-000000000004','beta-super@r90ct.local'),
 ('90200000-0001-0000-0000-000000000005','beta-staff2@r90ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('90200000-0001-0000-0000-000000000001','90200000-0000-0000-0000-000000000001','R90C-1','Alpha Staff','alpha-staff@r90ct.local',true),
 ('90200000-0001-0000-0000-000000000002','90200000-0000-0000-0000-000000000001','R90C-2','Alpha Super','alpha-super@r90ct.local',true),
 ('90200000-0001-0000-0000-000000000003','90200000-0000-0000-0000-000000000002','R90C-3','Beta Staff','beta-staff@r90ct.local',true),
 ('90200000-0001-0000-0000-000000000004','90200000-0000-0000-0000-000000000002','R90C-4','Beta Super','beta-super@r90ct.local',true),
 ('90200000-0001-0000-0000-000000000005','90200000-0000-0000-0000-000000000002','R90C-5','Beta Staff Two','beta-staff2@r90ct.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('90200000-0001-0000-0000-000000000001','section','90200000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('90200000-0001-0000-0000-000000000002','section','90200000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
 ('90200000-0001-0000-0000-000000000003','section','90200000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('90200000-0001-0000-0000-000000000004','section','90200000-0002-0000-0000-000000000002','mcs_admin',TRUE,TRUE),
 ('90200000-0001-0000-0000-000000000005','section','90200000-0002-0000-0000-000000000002','staff',TRUE,TRUE);

-- Two requests: R1 (main, drives most scenarios), R2 (unrelated,
-- proves independence -- scenario 7).
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000002','R1','B1','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('app.r90c_r1', v_req.id::text, false);
  v_req := create_request('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000002','R2 (unrelated)','B2','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('app.r90c_r2', v_req.id::text, false);
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(current_setting('app.r90c_r1')::uuid, NULL);
  v_req := approve_request(current_setting('app.r90c_r2')::uuid, NULL);
  RESET ROLE;
END $$;

-- ── 1. Two workers race to drain the SAME requests.sent.v1 event
-- (produced by a single genuine approve_request() call on R1) -- SKIP
-- LOCKED guarantees exactly one worker processes it. ───────────────
SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'SET ROLE service_role');
SELECT dblink_exec('c2', 'SET ROLE service_role');
SELECT dblink_send_query('c1', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'r90c-w1') WHERE event_type='requests.sent.v1'$q$);
SELECT dblink_send_query('c2', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'r90c-w2') WHERE event_type='requests.sent.v1'$q$);
SELECT * FROM dblink_get_result('c1') AS t(event_id UUID, outcome TEXT);
SELECT * FROM dblink_get_result('c2') AS t(event_id UUID, outcome TEXT);
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90c_r1')::uuid AND status='completed';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the single requests.sent.v1 event to reach completed exactly once, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='requests.sent.v1' AND source_record_id = current_setting('app.r90c_r1')::uuid AND recipient_user_id='90200000-0001-0000-0000-000000000004';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly one notification for Beta Admin despite two racing workers, got %', v_count; END IF;
END $$;
INSERT INTO r90c_results VALUES (1,'Two workers racing to claim the same real requests.sent.v1 event (SKIP LOCKED) resolve exactly like Phase 1.3''s own generic-envelope race: no duplicate processing, exactly one user_notification per genuine recipient');

-- ── 2. Two concurrent assign_request() calls on the SAME request
-- (route it first) -- both legitimately succeed serially (assign_
-- request has no status guard beyond org/role authorization), each
-- producing its own distinct requests.assigned.v1 occurrence -- "two
-- assignments" race. ─────────────────────────────────────────────────
DO $$
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(current_setting('app.r90c_r1')::uuid);
  PERFORM route_request(current_setting('app.r90c_r1')::uuid, '90200000-0002-0000-0000-000000000002');
  RESET ROLE;
END $$;

SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'SET ROLE authenticated');
SELECT dblink_exec('c2', 'SET ROLE authenticated');
SELECT dblink_exec('c1', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',false); END $inner$;$q$);
SELECT dblink_exec('c2', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',false); END $inner$;$q$);
SELECT dblink_send_query('c1', format($q$SELECT assign_request('%s', '90200000-0001-0000-0000-000000000003')$q$, current_setting('app.r90c_r1')));
SELECT dblink_send_query('c2', format($q$SELECT assign_request('%s', '90200000-0001-0000-0000-000000000005')$q$, current_setting('app.r90c_r1')));
SELECT * FROM dblink_get_result('c1') AS t(result TEXT);
SELECT * FROM dblink_get_result('c2') AS t(result TEXT);
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER; v_final UUID;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.assigned.v1' AND source_record_id = current_setting('app.r90c_r1')::uuid;
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 distinct requests.assigned.v1 occurrences from two concurrent assign_request() calls, got %', v_count; END IF;
  SELECT assigned_to INTO v_final FROM requests WHERE id = current_setting('app.r90c_r1')::uuid;
  IF v_final NOT IN ('90200000-0001-0000-0000-000000000003','90200000-0001-0000-0000-000000000005') THEN
    RAISE EXCEPTION 'final assigned_to is neither racing candidate -- torn state';
  END IF;
END $$;
INSERT INTO r90c_results VALUES (2,'Two genuinely concurrent assign_request() calls on the same request (two different assignees) both succeed serially -- the request ends assigned to whichever won the row lock last, and BOTH calls produce their own distinct, independently-idempotency-keyed requests.assigned.v1 occurrence -- no torn state, no lost event');

-- ── 3. approve_request() vs return_request() racing on the SAME
-- pending_approval request -- the status guard (pending_approval only)
-- allows exactly one to win; the loser is rejected before reaching the
-- enqueue -- "approve/return race". ─────────────────────────────────
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000002','R3 (race)','B3','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  RESET ROLE;
  PERFORM set_config('app.r90c_r3', v_req.id::text, false);
END $$;

DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  PERFORM dblink_connect('c1', 'dbname=cap002_p53');
  PERFORM dblink_connect('c2', 'dbname=cap002_p53');
  PERFORM dblink_exec('c1', 'SET ROLE authenticated');
  PERFORM dblink_exec('c2', 'SET ROLE authenticated');
  PERFORM dblink_exec('c1', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
  PERFORM dblink_exec('c2', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
  PERFORM dblink_send_query('c1', format($q$SELECT (approve_request('%s'::uuid, NULL)).status$q$, current_setting('app.r90c_r3')));
  PERFORM dblink_send_query('c2', format($q$SELECT (return_request('%s'::uuid, NULL)).status$q$, current_setting('app.r90c_r3')));

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
    RAISE EXCEPTION 'expected exactly one of approve_request/return_request to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
END $$;

DO $$
DECLARE v_status TEXT; v_sent INTEGER; v_returned INTEGER;
BEGIN
  SELECT status INTO v_status FROM requests WHERE id = current_setting('app.r90c_r3')::uuid;
  IF v_status NOT IN ('sent','draft') THEN RAISE EXCEPTION 'unexpected final status: %', v_status; END IF;
  SELECT count(*) INTO v_sent FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90c_r3')::uuid;
  SELECT count(*) INTO v_returned FROM platform_outbox_events WHERE event_type='requests.returned.v1' AND source_record_id = current_setting('app.r90c_r3')::uuid;
  IF v_sent + v_returned <> 1 THEN
    RAISE EXCEPTION 'expected exactly ONE of requests.sent.v1/requests.returned.v1 to have fired (mutually exclusive status guard), got sent=% returned=%', v_sent, v_returned;
  END IF;
  IF v_status = 'sent' AND v_sent <> 1 THEN RAISE EXCEPTION 'status is sent but requests.sent.v1 did not fire'; END IF;
  IF v_status = 'draft' AND v_returned <> 1 THEN RAISE EXCEPTION 'status is draft but requests.returned.v1 did not fire'; END IF;
END $$;
INSERT INTO r90c_results VALUES (3,'approve_request() and return_request() racing concurrently on the SAME pending_approval request are mutually exclusive via the pre-existing status guard -- exactly ONE of requests.sent.v1/requests.returned.v1 fires, matching whichever call actually won the row lock and changed status; the loser is rejected before reaching its enqueue -- no double-fire, no torn state');

-- ── 4. Response submission race: two concurrent approve_response()
-- calls on the SAME response -- only one wins (status guard), exactly
-- one requests.response_sent.v1 event. ─────────────────────────────
DO $$
DECLARE v_req requests; v_resp responses;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000002','R4 (resp race)','B4','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90200000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000003"}',true);
  v_resp := create_response(v_req.id, 'resp body', 'en');
  PERFORM submit_response(v_resp.id, NULL);
  RESET ROLE;
  PERFORM set_config('app.r90c_resp4', v_resp.id::text, false);
  PERFORM set_config('app.r90c_r4', v_req.id::text, false);
END $$;

DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  PERFORM dblink_connect('c1', 'dbname=cap002_p53');
  PERFORM dblink_connect('c2', 'dbname=cap002_p53');
  PERFORM dblink_exec('c1', 'SET ROLE authenticated');
  PERFORM dblink_exec('c2', 'SET ROLE authenticated');
  PERFORM dblink_exec('c1', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',false); END $inner$;$q$);
  PERFORM dblink_exec('c2', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',false); END $inner$;$q$);
  PERFORM dblink_send_query('c1', format($q$SELECT (approve_response('%s'::uuid, 'race-1')).status$q$, current_setting('app.r90c_resp4')));
  PERFORM dblink_send_query('c2', format($q$SELECT (approve_response('%s'::uuid, 'race-2')).status$q$, current_setting('app.r90c_resp4')));

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
    RAISE EXCEPTION 'expected exactly one of the two concurrent approve_response() calls to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
END $$;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.response_sent.v1' AND source_record_id = current_setting('app.r90c_r4')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 requests.response_sent.v1 event despite two racing approve_response() calls, got %', v_count; END IF;
END $$;
INSERT INTO r90c_results VALUES (4,'Two concurrent approve_response() calls on the same response race the pre-existing status guard (pending_approval only) -- exactly one wins and produces exactly one requests.response_sent.v1 event; the loser is rejected before reaching the enqueue');

-- ── 5. Worker processing races a section-membership change for
-- requests.routed.v1 (a member deactivated mid-flight of a real
-- worker run, in a separate concurrent session). ────────────────────
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90200000-0002-0000-0000-000000000001','90200000-0000-0000-0000-000000000002','R5 (membership race)','B5','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90200000-0002-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.r90c_r5', v_req.id::text, false);
END $$;

SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'BEGIN');
SELECT dblink_exec('c1', $q$UPDATE user_assignments SET is_active = FALSE WHERE user_id = '90200000-0001-0000-0000-000000000005' AND scope_id = '90200000-0002-0000-0000-000000000002'$q$);
-- Worker processes concurrently, in a SEPARATE session, before c1 commits.
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c2', 'SET ROLE service_role');
SELECT dblink_send_query('c2', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'r90c-w3') WHERE event_type='requests.routed.v1'$q$);
SELECT * FROM dblink_get_result('c2') AS t(event_id UUID, outcome TEXT);
SELECT dblink_exec('c1', 'COMMIT');
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER;
BEGIN
  -- Documented allowed serial outcomes, exactly matching Phase 1.4B's
  -- own meeting_participants precedent (docs/78 Sec7.2): 0 or 1,
  -- never duplicate.
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='requests.routed.v1' AND recipient_user_id='90200000-0001-0000-0000-000000000005' AND source_record_id = current_setting('app.r90c_r5')::uuid;
  IF v_count NOT IN (0, 1) THEN RAISE EXCEPTION 'expected 0 or 1 (never duplicate), got %', v_count; END IF;
  UPDATE user_assignments SET is_active = TRUE WHERE user_id = '90200000-0001-0000-0000-000000000005' AND scope_id = '90200000-0002-0000-0000-000000000002';
END $$;
INSERT INTO r90c_results VALUES (5,'A section-membership deactivation racing the worker''s own resolution of a real requests.routed.v1 event never produces a duplicate notification -- exactly 0 or 1 rows, both documented as legitimate serial outcomes depending on transaction-commit ordering (docs/78 Sec7.2 late-resolution)');

-- ── 6. Duplicate command replay: re-invoking approve_request() a
-- second time on an already-sent request is rejected by the
-- pre-existing status guard, producing no second outbox event. ─────
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90200000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM approve_request(current_setting('app.r90c_r1')::uuid, NULL); -- already sent (scenario 1)
  EXCEPTION WHEN OTHERS THEN
    v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'expected the replayed approve_request() call to be rejected'; END IF;
END $$;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90c_r1')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 requests.sent.v1 event despite a rejected replay attempt, got %', v_count; END IF;
END $$;
INSERT INTO r90c_results VALUES (6,'Replaying approve_request() on an already-sent request is rejected by the pre-existing, unmodified status guard before reaching the new atomic enqueue -- exactly 1 requests.sent.v1 event exists, no duplicate from the rejected replay attempt');

-- ── 7. Unrelated Requests proceed independently while the above races
-- are in flight -- R2 was deliberately left untouched by every
-- scenario above. ───────────────────────────────────────────────────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM requests WHERE id = current_setting('app.r90c_r2')::uuid;
  IF v_status <> 'sent' THEN RAISE EXCEPTION 'unrelated request R2 unexpectedly changed state (expected still sent, got %)', v_status; END IF;
END $$;
INSERT INTO r90c_results VALUES (7,'An unrelated request (R2) proceeds independently and is unaffected by any of the racing scenarios above on R1/R3/R4/R5 -- no cross-request interference, no global lock contention beyond each mutation''s own already-existing per-row locking');

-- ── 8. No deadlock across all scenarios above -- no lingering lock
-- remains from any dblink session. ──────────────────────────────────
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
    WHERE c.relname IN ('requests','responses','platform_outbox_events','user_assignments')
      AND l.pid <> pg_backend_pid();
  IF v_count <> 0 THEN RAISE EXCEPTION 'unexpected lingering lock(s) from a prior dblink session -- possible deadlock/leak, got %', v_count; END IF;
END $$;
INSERT INTO r90c_results VALUES (8,'No deadlock across any of the above scenarios -- all dblink sessions were cleanly disconnected and no lingering lock remains on any Requests/CAP-003 table');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM r90c_results;
  IF v_count <> 8 THEN RAISE EXCEPTION 'expected 8 concurrency scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Requests notification integration concurrency tests PASSED: 8/8';
END $$;

-- ── Cleanup (top-level fixtures, no wrapping transaction due to
-- dblink's own separate-session requirement). requests/responses use
-- gen_random_uuid() PKs (never the '90200000-%' fixture prefix), so
-- they are located via their organization columns instead. ─────────
DELETE FROM user_notifications WHERE recipient_user_id::text LIKE '90200000-%' OR outbox_event_id IN (SELECT id FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%') OR actor_id::text LIKE '90200000-%');
DELETE FROM notification_intents WHERE outbox_event_id IN (SELECT id FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%') OR actor_id::text LIKE '90200000-%');
DELETE FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%') OR actor_id::text LIKE '90200000-%';
DELETE FROM approvals WHERE record_id IN (SELECT id FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%')
  OR record_id IN (SELECT resp.id FROM responses resp JOIN requests q ON q.id = resp.request_id WHERE q.from_org_id::text LIKE '90200000-%' OR q.to_org_id::text LIKE '90200000-%');
DELETE FROM responses WHERE request_id IN (SELECT id FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%');
DELETE FROM audit_logs WHERE user_id::text LIKE '90200000-%';
DELETE FROM requests WHERE from_org_id::text LIKE '90200000-%' OR to_org_id::text LIKE '90200000-%';
DELETE FROM reference_sequences WHERE section_id::text LIKE '90200000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '90200000-%';
DELETE FROM users WHERE id::text LIKE '90200000-%';
DELETE FROM auth.users WHERE id::text LIKE '90200000-%';
DELETE FROM sections WHERE id::text LIKE '90200000-%';
DELETE FROM divisions WHERE id::text LIKE '90200000-%';
DELETE FROM organizations WHERE id::text LIKE '90200000-%';
DELETE FROM r90c_results;
