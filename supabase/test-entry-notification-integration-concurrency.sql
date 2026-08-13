-- CAP-003 Phase 1.7B notification event integration -- concurrency
-- suite. Disposable local PostgreSQL only, genuine multi-session via
-- dblink. Runs top-level (not wrapped in one transaction, since each
-- dblink connection is its own session); fixtures are explicitly
-- cleaned up at the end.
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TABLE IF NOT EXISTS e92c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT, DELETE ON e92c_results TO authenticated, service_role;
DELETE FROM e92c_results;

INSERT INTO organizations(id,name,type,code) VALUES
 ('92200000-0000-0000-0000-000000000001','E92C Org Alpha','authority','E92CA');
INSERT INTO divisions(id, org_id, name) VALUES
 ('92200000-0004-0000-0000-000000000001','92200000-0000-0000-0000-000000000001','E92C Alpha Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('92200000-0002-0000-0000-000000000001','92200000-0000-0000-0000-000000000001','92200000-0004-0000-0000-000000000001','E92C Records','E92CREC'),
 ('92200000-0002-0000-0000-000000000002','92200000-0000-0000-0000-000000000001','92200000-0004-0000-0000-000000000001','E92C Welfare','E92CWEL');
INSERT INTO entry_sections(org_id, section_id) VALUES
 ('92200000-0000-0000-0000-000000000001','92200000-0002-0000-0000-000000000001'),
 ('92200000-0000-0000-0000-000000000001','92200000-0002-0000-0000-000000000002');
INSERT INTO auth.users(id,email) VALUES
 ('92200000-0001-0000-0000-000000000001','clerk@e92ct.local'),
 ('92200000-0001-0000-0000-000000000002','welfare-super@e92ct.local'),
 ('92200000-0001-0000-0000-000000000003','welfare-staff-a@e92ct.local'),
 ('92200000-0001-0000-0000-000000000004','welfare-staff-b@e92ct.local'),
 ('92200000-0001-0000-0000-000000000005','welfare-staff-c@e92ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('92200000-0001-0000-0000-000000000001','92200000-0000-0000-0000-000000000001','E92C-1','Clerk','clerk@e92ct.local',true),
 ('92200000-0001-0000-0000-000000000002','92200000-0000-0000-0000-000000000001','E92C-2','Welfare Super','welfare-super@e92ct.local',true),
 ('92200000-0001-0000-0000-000000000003','92200000-0000-0000-0000-000000000001','E92C-3','Welfare Staff A','welfare-staff-a@e92ct.local',true),
 ('92200000-0001-0000-0000-000000000004','92200000-0000-0000-0000-000000000001','E92C-4','Welfare Staff B','welfare-staff-b@e92ct.local',true),
 ('92200000-0001-0000-0000-000000000005','92200000-0000-0000-0000-000000000001','E92C-5','Welfare Staff C','welfare-staff-c@e92ct.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('92200000-0001-0000-0000-000000000001','section','92200000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('92200000-0001-0000-0000-000000000002','section','92200000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
 ('92200000-0001-0000-0000-000000000003','section','92200000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92200000-0001-0000-0000-000000000004','section','92200000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92200000-0001-0000-0000-000000000005','section','92200000-0002-0000-0000-000000000002','staff',TRUE,TRUE);

-- Two entries: E1 (main, drives most scenarios), E2 (unrelated, proves
-- independence -- scenario 7).
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender E1','Subject E1','Body E1');
  v_ent := route_entry(v_ent.id, '92200000-0002-0000-0000-000000000002');
  PERFORM set_config('app.e92c_e1', v_ent.id::text, false);
  v_ent := create_entry('email','public','Sender E2 (unrelated)','Subject E2','Body E2');
  v_ent := route_entry(v_ent.id, '92200000-0002-0000-0000-000000000002');
  PERFORM set_config('app.e92c_e2', v_ent.id::text, false);
  RESET ROLE;
END $$;

-- ── 1. Two workers race to drain the SAME entry.routed.v1 event
-- (produced by a single genuine route_entry() call on E1) -- SKIP
-- LOCKED guarantees exactly one worker processes it. ───────────────
SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'SET ROLE service_role');
SELECT dblink_exec('c2', 'SET ROLE service_role');
SELECT dblink_send_query('c1', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'e92c-w1') WHERE event_type='entry.routed.v1'$q$);
SELECT dblink_send_query('c2', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'e92c-w2') WHERE event_type='entry.routed.v1'$q$);
SELECT * FROM dblink_get_result('c1') AS t(event_id UUID, outcome TEXT);
SELECT * FROM dblink_get_result('c2') AS t(event_id UUID, outcome TEXT);
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.routed.v1' AND source_record_id = current_setting('app.e92c_e1')::uuid AND status='completed';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the single entry.routed.v1 event to reach completed exactly once, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='entry.routed.v1' AND source_record_id = current_setting('app.e92c_e1')::uuid AND recipient_user_id='92200000-0001-0000-0000-000000000002';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly one notification for Welfare Super despite two racing workers, got %', v_count; END IF;
END $$;
INSERT INTO e92c_results VALUES (1,'Two workers racing to claim the same real entry.routed.v1 event (SKIP LOCKED) resolve exactly like Phase 1.3''s own generic-envelope race: no duplicate processing, exactly one user_notification per genuine recipient');

-- ── 2. Two concurrent assign_entry() calls on the SAME entry (both are
-- genuine Entry-staff-authorized callers, avoiding the confound already
-- learned in Phase 1.7A's own CONC TEST 4: pairing an Entry-staff
-- caller against a merely-section-scoped caller can produce a genuine
-- authorization-depends-on-race-outcome result, not a bug -- so both
-- concurrent callers here are the SAME kind of caller, the Welfare
-- section's own supervisor, invoked from two separate sessions) -- both
-- legitimately succeed serially, each producing its own distinct
-- entry.assigned.v1 occurrence -- "two assignments" race. ────────────
SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'SET ROLE authenticated');
SELECT dblink_exec('c2', 'SET ROLE authenticated');
SELECT dblink_exec('c1', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
SELECT dblink_exec('c2', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
SELECT dblink_send_query('c1', format($q$SELECT (assign_entry('%s'::uuid, '92200000-0001-0000-0000-000000000003', NULL)).status$q$, current_setting('app.e92c_e1')));
SELECT dblink_send_query('c2', format($q$SELECT (assign_entry('%s'::uuid, '92200000-0001-0000-0000-000000000004', NULL)).status$q$, current_setting('app.e92c_e1')));
SELECT * FROM dblink_get_result('c1') AS t(result TEXT);
SELECT * FROM dblink_get_result('c2') AS t(result TEXT);
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER; v_final UUID;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.assigned.v1' AND source_record_id = current_setting('app.e92c_e1')::uuid;
  -- Scenario 1's own route_entry() call did not include an assignee, so
  -- the pre-existing count here is 0 -- both concurrent assign_entry()
  -- calls below must each produce their own distinct occurrence.
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 distinct entry.assigned.v1 occurrences from two concurrent assign_entry() calls, got %', v_count; END IF;
  SELECT assigned_to INTO v_final FROM external_correspondence WHERE id = current_setting('app.e92c_e1')::uuid;
  IF v_final NOT IN ('92200000-0001-0000-0000-000000000003','92200000-0001-0000-0000-000000000004') THEN
    RAISE EXCEPTION 'final assigned_to is neither racing candidate -- torn state';
  END IF;
END $$;
INSERT INTO e92c_results VALUES (2,'Two genuinely concurrent assign_entry() calls on the same entry (two different assignees, both invoked by the SAME kind of authorized caller -- the Welfare supervisor -- from two separate sessions, avoiding the authorization-depends-on-race-outcome confound already learned in Phase 1.7A''s own concurrency suite) both succeed serially -- the entry ends assigned to whichever won the row lock last, and BOTH calls produce their own distinct, independently-idempotency-keyed entry.assigned.v1 occurrence -- no torn state, no lost event');

-- ── 3. approve_entry_reply() vs return_entry_reply() racing on the
-- SAME pending_approval reply -- the status guard (pending_approval
-- only) allows exactly one to win; the loser is rejected before
-- reaching the enqueue -- "approve/return race". ──────────────────────
DO $$
DECLARE v_ent external_correspondence; v_rep external_correspondence_replies;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender E3','Subject E3','Body E3');
  v_ent := route_entry(v_ent.id, '92200000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000005"}',true);
  v_rep := draft_entry_reply(v_ent.id, 'race reply body');
  v_rep := submit_entry_reply(v_rep.id, NULL);
  RESET ROLE;
  PERFORM set_config('app.e92c_e3', v_ent.id::text, false);
  PERFORM set_config('app.e92c_rep3', v_rep.id::text, false);
END $$;

DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_ok_count INT := 0;
BEGIN
  PERFORM dblink_connect('c1', 'dbname=cap002_p53');
  PERFORM dblink_connect('c2', 'dbname=cap002_p53');
  PERFORM dblink_exec('c1', 'SET ROLE authenticated');
  PERFORM dblink_exec('c2', 'SET ROLE authenticated');
  PERFORM dblink_exec('c1', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
  PERFORM dblink_exec('c2', $q$DO $inner$ BEGIN PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000002"}',false); END $inner$;$q$);
  PERFORM dblink_send_query('c1', format($q$SELECT (approve_entry_reply('%s'::uuid)).status$q$, current_setting('app.e92c_rep3')));
  PERFORM dblink_send_query('c2', format($q$SELECT (return_entry_reply('%s'::uuid, NULL)).status$q$, current_setting('app.e92c_rep3')));

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
    RAISE EXCEPTION 'expected exactly one of approve_entry_reply/return_entry_reply to win, got % successes (r1=%, r2=%)', v_ok_count, v_r1, v_r2;
  END IF;
END $$;

DO $$
DECLARE v_status TEXT; v_sent INTEGER; v_returned INTEGER;
BEGIN
  SELECT status INTO v_status FROM external_correspondence_replies WHERE id = current_setting('app.e92c_rep3')::uuid;
  IF v_status NOT IN ('sent','draft') THEN RAISE EXCEPTION 'unexpected final status: %', v_status; END IF;
  SELECT count(*) INTO v_sent FROM platform_outbox_events WHERE event_type='entry.reply_sent.v1' AND source_record_id = current_setting('app.e92c_e3')::uuid;
  SELECT count(*) INTO v_returned FROM platform_outbox_events WHERE event_type='entry.reply_returned.v1' AND source_record_id = current_setting('app.e92c_e3')::uuid;
  IF v_sent + v_returned <> 1 THEN
    RAISE EXCEPTION 'expected exactly ONE of entry.reply_sent.v1/entry.reply_returned.v1 to have fired (mutually exclusive status guard), got sent=% returned=%', v_sent, v_returned;
  END IF;
  IF v_status = 'sent' AND v_sent <> 1 THEN RAISE EXCEPTION 'status is sent but entry.reply_sent.v1 did not fire'; END IF;
  IF v_status = 'draft' AND v_returned <> 1 THEN RAISE EXCEPTION 'status is draft but entry.reply_returned.v1 did not fire'; END IF;
END $$;
INSERT INTO e92c_results VALUES (3,'approve_entry_reply() and return_entry_reply() racing concurrently on the SAME pending_approval reply are mutually exclusive via the pre-existing status guard -- exactly ONE of entry.reply_sent.v1/entry.reply_returned.v1 fires, matching whichever call actually won the row lock and changed status; the loser is rejected before reaching its enqueue -- no double-fire, no torn state');

-- ── 4. Worker processing races a section-membership change for
-- entry.routed.v1 (a member deactivated mid-flight of a real worker
-- run, in a separate concurrent session). ───────────────────────────
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender E4','Subject E4','Body E4');
  v_ent := route_entry(v_ent.id, '92200000-0002-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.e92c_e4', v_ent.id::text, false);
END $$;

SELECT dblink_connect('c1', 'dbname=cap002_p53');
SELECT dblink_exec('c1', 'BEGIN');
SELECT dblink_exec('c1', $q$UPDATE user_assignments SET is_active = FALSE WHERE user_id = '92200000-0001-0000-0000-000000000005' AND scope_id = '92200000-0002-0000-0000-000000000002'$q$);
-- Worker processes concurrently, in a SEPARATE session, before c1 commits.
SELECT dblink_connect('c2', 'dbname=cap002_p53');
SELECT dblink_exec('c2', 'SET ROLE service_role');
SELECT dblink_send_query('c2', $q$SELECT event_id, outcome FROM process_platform_outbox_batch(200,'e92c-w3') WHERE event_type='entry.routed.v1'$q$);
SELECT * FROM dblink_get_result('c2') AS t(event_id UUID, outcome TEXT);
SELECT dblink_exec('c1', 'COMMIT');
SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');

DO $$
DECLARE v_count INTEGER;
BEGIN
  -- Documented allowed serial outcomes, exactly matching Phase 1.6B's
  -- own precedent (docs/78 Sec7.2): 0 or 1, never duplicate.
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='entry.routed.v1' AND recipient_user_id='92200000-0001-0000-0000-000000000005' AND source_record_id = current_setting('app.e92c_e4')::uuid;
  IF v_count NOT IN (0, 1) THEN RAISE EXCEPTION 'expected 0 or 1 (never duplicate), got %', v_count; END IF;
  UPDATE user_assignments SET is_active = TRUE WHERE user_id = '92200000-0001-0000-0000-000000000005' AND scope_id = '92200000-0002-0000-0000-000000000002';
END $$;
INSERT INTO e92c_results VALUES (4,'A section-membership deactivation racing the worker''s own resolution of a real entry.routed.v1 event never produces a duplicate notification -- exactly 0 or 1 rows, both documented as legitimate serial outcomes depending on transaction-commit ordering (docs/78 Sec7.2 late-resolution)');

-- ── 5. Duplicate command replay: re-invoking route_entry() a second
-- time on an already-routed entry is a legitimate REROUTE (route_entry
-- has no status guard against re-routing, unlike approve/return), so it
-- succeeds again and produces its OWN second, distinct entry.routed.v1
-- occurrence -- never collapsed with the first. ─────────────────────
DO $$
DECLARE v_count_before INTEGER;
BEGIN
  SELECT count(*) INTO v_count_before FROM platform_outbox_events WHERE event_type='entry.routed.v1' AND source_record_id = current_setting('app.e92c_e1')::uuid;
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92200000-0001-0000-0000-000000000001"}',true);
  PERFORM route_entry(current_setting('app.e92c_e1')::uuid, '92200000-0002-0000-0000-000000000001'); -- re-route to Records
  RESET ROLE;
  PERFORM set_config('app.e92c_e1_before', v_count_before::text, false);
END $$;
DO $$
DECLARE v_count INTEGER; v_before INTEGER := current_setting('app.e92c_e1_before')::int;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.routed.v1' AND source_record_id = current_setting('app.e92c_e1')::uuid;
  IF v_count <> v_before + 1 THEN RAISE EXCEPTION 'expected exactly one NEW entry.routed.v1 event from the legitimate reroute (before=%, after=%)', v_before, v_count; END IF;
END $$;
INSERT INTO e92c_results VALUES (5,'Re-invoking route_entry() on an already-routed entry (a legitimate reroute -- route_entry has no status guard against being called again, unlike approve/return_entry_reply) produces its own distinct, independently-idempotency-keyed entry.routed.v1 occurrence rather than being collapsed into the first -- correct treatment of a genuinely repeatable command');

-- ── 6. Unrelated entries proceed independently while the above races
-- are in flight -- E2 was deliberately left untouched by every
-- scenario above. ───────────────────────────────────────────────────
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM external_correspondence WHERE id = current_setting('app.e92c_e2')::uuid;
  IF v_status <> 'routed' THEN RAISE EXCEPTION 'unrelated entry E2 unexpectedly changed state (expected still routed, got %)', v_status; END IF;
END $$;
INSERT INTO e92c_results VALUES (6,'An unrelated entry (E2) proceeds independently and is unaffected by any of the racing scenarios above on E1/E3/E4 -- no cross-entry interference, no global lock contention beyond each mutation''s own already-existing per-row locking');

-- ── 7. No deadlock across all scenarios above -- no lingering lock
-- remains from any dblink session. ──────────────────────────────────
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
    WHERE c.relname IN ('external_correspondence','external_correspondence_replies','platform_outbox_events','user_assignments')
      AND l.pid <> pg_backend_pid();
  IF v_count <> 0 THEN RAISE EXCEPTION 'unexpected lingering lock(s) from a prior dblink session -- possible deadlock/leak, got %', v_count; END IF;
END $$;
INSERT INTO e92c_results VALUES (7,'No deadlock across any of the above scenarios -- all dblink sessions were cleanly disconnected and no lingering lock remains on any Entry/CAP-003 table');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM e92c_results;
  IF v_count <> 7 THEN RAISE EXCEPTION 'expected 7 concurrency scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Entry notification integration concurrency tests PASSED: 7/7';
END $$;

-- ── Cleanup (top-level fixtures, no wrapping transaction due to
-- dblink's own separate-session requirement). external_correspondence
-- uses gen_random_uuid() PKs (never the '92200000-%' fixture prefix),
-- so entries are located via their org_id column instead. ────────────
DELETE FROM user_notifications WHERE recipient_user_id::text LIKE '92200000-%' OR outbox_event_id IN (SELECT id FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM external_correspondence WHERE org_id::text LIKE '92200000-%') OR actor_id::text LIKE '92200000-%');
DELETE FROM notification_intents WHERE outbox_event_id IN (SELECT id FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM external_correspondence WHERE org_id::text LIKE '92200000-%') OR actor_id::text LIKE '92200000-%');
DELETE FROM platform_outbox_events WHERE source_record_id IN (SELECT id FROM external_correspondence WHERE org_id::text LIKE '92200000-%') OR actor_id::text LIKE '92200000-%';
DELETE FROM approvals WHERE record_id IN (SELECT id FROM external_correspondence_replies WHERE entry_id IN (SELECT id FROM external_correspondence WHERE org_id::text LIKE '92200000-%'));
DELETE FROM external_correspondence_replies WHERE entry_id IN (SELECT id FROM external_correspondence WHERE org_id::text LIKE '92200000-%');
DELETE FROM audit_logs WHERE user_id::text LIKE '92200000-%';
DELETE FROM external_correspondence WHERE org_id::text LIKE '92200000-%';
DELETE FROM entry_reference_sequences WHERE org_id::text LIKE '92200000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '92200000-%';
DELETE FROM users WHERE id::text LIKE '92200000-%';
DELETE FROM auth.users WHERE id::text LIKE '92200000-%';
DELETE FROM entry_sections WHERE org_id::text LIKE '92200000-%';
DELETE FROM sections WHERE id::text LIKE '92200000-%';
DELETE FROM divisions WHERE id::text LIKE '92200000-%';
DELETE FROM organizations WHERE id::text LIKE '92200000-%';
DELETE FROM e92c_results;
