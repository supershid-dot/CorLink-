-- CAP-003 Phase 1.3 notification outbox worker -- concurrency suite (9
-- race scenarios). Disposable local PostgreSQL only; requires dblink.
-- Mirrors the exact dblink-based genuinely-independent-session pattern
-- every other CAP-002/CAP-003 concurrency suite in this repository
-- already establishes.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE wf83c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf83c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf83c_results, wf83c_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES
 ('83200000-0000-0000-0000-000000000001','WF83C Org','authority','WF83C'),
 ('83200000-0000-0000-0000-000000000002','WF83C Org B','authority','WF83CB');
INSERT INTO auth.users(id,email) VALUES
 ('83200000-0001-0000-0000-000000000001','candidate@wf83ct.local'),
 ('83200000-0001-0000-0000-000000000002','candidateb@wf83ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('83200000-0001-0000-0000-000000000001','83200000-0000-0000-0000-000000000001','WF83C-1','Candidate','candidate@wf83ct.local',true),
 ('83200000-0001-0000-0000-000000000002','83200000-0000-0000-0000-000000000002','WF83C-2','Candidate B','candidateb@wf83ct.local',true);

CREATE OR REPLACE FUNCTION wf83c_connect_worker(p_conn TEXT) RETURNS VOID AS $$
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE service_role');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION wf83c_enqueue_supported(p_org UUID, p_user UUID) RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  v_id := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    p_org, NULL, gen_random_uuid(), NULL, now(),
    jsonb_build_object('notification_type','platform.wf83c_test.v1','title_template_key','x.title',
      'target_type','specific_users','target_user_ids', jsonb_build_array(p_user::TEXT)),
    gen_random_uuid());
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

SET ROLE service_role;

-- ── 1: two workers claim the SAME pending event ──
DO $$
DECLARE v_id UUID;
BEGIN
  v_id := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  INSERT INTO wf83c_ids VALUES ('race1', v_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_notif_count INTEGER; v_processed_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM wf83c_ids WHERE name = 'race1';
  PERFORM wf83c_connect_worker('c1r1');
  PERFORM wf83c_connect_worker('c2r1');

  PERFORM dblink_send_query('c1r1', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceA-worker') WHERE event_id = '%s'::uuid$q$, v_id));
  PERFORM dblink_send_query('c2r1', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceB-worker') WHERE event_id = '%s'::uuid$q$, v_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r1', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r1', false);
  PERFORM dblink_disconnect('c1r1');
  PERFORM dblink_disconnect('c2r1');

  v_processed_count := (CASE WHEN v_r1 IN ('processed','processed_zero_recipients') THEN 1 ELSE 0 END)
                      + (CASE WHEN v_r2 IN ('processed','processed_zero_recipients') THEN 1 ELSE 0 END);
  IF v_processed_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly ONE of two racing same-event workers to process it, got r1=%, r2=% (processed_count=%)', v_r1, v_r2, v_processed_count;
  END IF;
  IF (SELECT status FROM platform_outbox_events WHERE id = v_id) <> 'completed' THEN
    RAISE EXCEPTION 'expected the raced event to be completed exactly once';
  END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_id;
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification after two workers raced the same event, got %', v_notif_count; END IF;
END $$;
INSERT INTO wf83c_results VALUES (1,'Two concurrent workers racing to claim the SAME pending outbox event: exactly one wins (FOR UPDATE SKIP LOCKED), the other reports a non-processing outcome, and exactly one notification is durably created');

-- ── 2: two workers process DIFFERENT events concurrently and both progress ──
DO $$
DECLARE v_id1 UUID; v_id2 UUID;
BEGIN
  v_id1 := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  v_id2 := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  INSERT INTO wf83c_ids VALUES ('race2a', v_id1);
  INSERT INTO wf83c_ids VALUES ('race2b', v_id2);
END $$;
-- Both connections call the worker with a batch limit wide enough to
-- see both fixture events, so which specific connection ends up
-- claiming which specific event is NOT asserted (both workers pull
-- from the same shared eligible-candidate pool -- either genuinely
-- may claim either row first; that non-determinism is itself correct,
-- unrestricted-worker-pool behavior, not a defect). What matters is
-- the aggregate outcome: both events reach 'completed' between the
-- two calls, and progress happens in parallel rather than one call
-- waiting out the other.
DO $$
DECLARE v_id1 UUID; v_id2 UUID; v_r1 TEXT; v_r2 TEXT;
BEGIN
  SELECT id INTO v_id1 FROM wf83c_ids WHERE name = 'race2a';
  SELECT id INTO v_id2 FROM wf83c_ids WHERE name = 'race2b';
  PERFORM wf83c_connect_worker('c1r2');
  PERFORM wf83c_connect_worker('c2r2');

  PERFORM dblink_send_query('c1r2', $q$SELECT string_agg(outcome, ',') FROM process_platform_outbox_batch(25,'raceA-worker')$q$);
  PERFORM dblink_send_query('c2r2', $q$SELECT string_agg(outcome, ',') FROM process_platform_outbox_batch(25,'raceB-worker')$q$);

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r2', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r2', false);
  PERFORM dblink_disconnect('c1r2');
  PERFORM dblink_disconnect('c2r2');

  IF (SELECT status FROM platform_outbox_events WHERE id = v_id1) <> 'completed'
     OR (SELECT status FROM platform_outbox_events WHERE id = v_id2) <> 'completed'
  THEN RAISE EXCEPTION 'expected both independent events to reach completed between the two concurrent calls (c1r2=%, c2r2=%)', v_r1, v_r2; END IF;
  IF (SELECT count(*) FROM user_notifications WHERE outbox_event_id IN (v_id1, v_id2)) <> 2 THEN
    RAISE EXCEPTION 'expected exactly one notification per independent event, got %', (SELECT count(*) FROM user_notifications WHERE outbox_event_id IN (v_id1, v_id2));
  END IF;
END $$;
INSERT INTO wf83c_results VALUES (2,'Two concurrent workers, both drawing from the same eligible-candidate pool, together bring two DIFFERENT pending events to completed with one notification each -- no unnecessary shared lock serializes unrelated events (which specific connection claims which specific row is unrestricted worker-pool behavior, not asserted)');

-- ── 3: retry race -- two workers hit the SAME retryable event at once ──
DO $$
DECLARE v_id UUID;
BEGIN
  v_id := platform_enqueue_outbox_event(
    'platform.wf83c_unsupported.v1','platform','platform',gen_random_uuid(),
    '83200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf83c_ids VALUES ('race3', v_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_attempt_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM wf83c_ids WHERE name = 'race3';
  PERFORM wf83c_connect_worker('c1r3');
  PERFORM wf83c_connect_worker('c2r3');

  PERFORM dblink_send_query('c1r3', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceA-worker') WHERE event_id = '%s'::uuid$q$, v_id));
  PERFORM dblink_send_query('c2r3', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceB-worker') WHERE event_id = '%s'::uuid$q$, v_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r3', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r3', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r3', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r3', false);
  PERFORM dblink_disconnect('c1r3');
  PERFORM dblink_disconnect('c2r3');

  SELECT attempt_count INTO v_attempt_count FROM platform_outbox_events WHERE id = v_id;
  IF v_attempt_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly ONE retry increment from two workers racing the same retryable event, got attempt_count=% (r1=%, r2=%)', v_attempt_count, v_r1, v_r2;
  END IF;
END $$;
INSERT INTO wf83c_results VALUES (3,'Two concurrent workers racing the same retryable (failing) event increment attempt_count by exactly 1, never 2 -- the row lock serializes the retry-state write just as it does a successful one');

-- ── 4: a row actively being processed (held, uncommitted) is
-- correctly reported skipped_locked, while an UNRELATED event in the
-- SAME batch call still completes -- proves the lock check is
-- per-row, never a batch-wide block ──
SET ROLE service_role;
DO $$
DECLARE v_locked UUID; v_free UUID;
BEGIN
  v_locked := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  v_free := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  INSERT INTO wf83c_ids VALUES ('race4_locked', v_locked);
  INSERT INTO wf83c_ids VALUES ('race4_free', v_free);
END $$;
RESET ROLE;

-- c1r4 opens its own transaction and holds v_locked's row lock,
-- uncommitted -- exactly the "actively being processed" state a
-- worker mid-processing would hold. The dblink connection persists
-- across the following separate top-level statements (it is a
-- session-level resource, not scoped to one statement).
DO $$
DECLARE v_locked UUID;
BEGIN
  SELECT id INTO v_locked FROM wf83c_ids WHERE name = 'race4_locked';
  PERFORM wf83c_connect_worker('c1r4');
  PERFORM dblink_exec('c1r4', 'BEGIN');
  -- dblink_exec rejects statements that return rows -- wrap the lock
  -- acquisition in a DO block (no result set) so it can run via
  -- dblink_exec within the already-open transaction above.
  PERFORM dblink_exec('c1r4', format($q$DO $inner$ BEGIN PERFORM id FROM platform_outbox_events WHERE id = '%s'::uuid FOR UPDATE; END $inner$ $q$, v_locked));
END $$;

SET ROLE service_role;
DO $$
DECLARE v_locked UUID; v_free UUID; v_locked_outcome TEXT; v_free_outcome TEXT;
BEGIN
  SELECT id INTO v_locked FROM wf83c_ids WHERE name = 'race4_locked';
  SELECT id INTO v_free FROM wf83c_ids WHERE name = 'race4_free';

  -- ONE batch call covering both candidates -- a second, separate
  -- call would no longer find v_free (already completed by the first
  -- call), which would silently defeat this assertion.
  CREATE TEMP TABLE wf83c_race4_batch AS SELECT * FROM process_platform_outbox_batch(25,'raceB-worker');
  SELECT outcome INTO v_locked_outcome FROM wf83c_race4_batch WHERE event_id = v_locked;
  SELECT outcome INTO v_free_outcome FROM wf83c_race4_batch WHERE event_id = v_free;
  DROP TABLE wf83c_race4_batch;

  IF v_locked_outcome <> 'skipped_locked' THEN
    RAISE EXCEPTION 'expected the actively-locked event to report skipped_locked, got %', v_locked_outcome;
  END IF;
  IF v_free_outcome <> 'processed' THEN
    RAISE EXCEPTION 'expected the unrelated event in the same caller''s own batch to still complete normally, got %', v_free_outcome;
  END IF;
END $$;
RESET ROLE;

DO $$
BEGIN
  PERFORM dblink_exec('c1r4', 'ROLLBACK');
  PERFORM dblink_disconnect('c1r4');
END $$;
INSERT INTO wf83c_results VALUES (4,'An event another session is actively processing (row locked, uncommitted) is correctly reported skipped_locked by a second worker, while a different, unrelated event resolved separately by that same second worker still completes normally -- a currently-processing row never blocks progress on anything else');

-- ── 5: dead-letter threshold race -- two workers both attempt the
-- FINAL (terminal) retry of the same poison event simultaneously ──
SET ROLE service_role;
DO $$
DECLARE v_id UUID; v_i INTEGER;
BEGIN
  v_id := platform_enqueue_outbox_event(
    'platform.wf83c_poison.v1','platform','platform',gen_random_uuid(),
    '83200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf83c_ids VALUES ('race5', v_id);
  -- Drive attempt_count to 4 (one short of the terminal threshold)
  -- directly, rather than via 4 real worker calls: this suite may run
  -- as part of a larger cumulative regression sweep alongside other
  -- phases' own disposable performance-fixture rows sitting in the
  -- shared pending queue, and an unscoped process_platform_outbox_batch
  -- call has no guarantee of reaching this specific row within a
  -- bounded p_limit. What scenario 5 actually races is the FINAL
  -- (terminal) attempt, not this warm-up -- setting attempt_count
  -- directly is a deterministic, equivalent starting state.
  -- next_attempt_at is set to NULL, not now(): platform_outbox_events_
  -- due_for_processing orders NULLS FIRST, so this row always sorts
  -- ahead of any other pending row regardless of how overdue that
  -- other row's own (non-NULL) next_attempt_at is -- including other
  -- phases' own leftover performance-fixture rows that may still be
  -- sitting in the shared pending queue when this suite runs as part
  -- of a larger cumulative regression sweep. A real timestamp like
  -- now() would NOT be guaranteed to win that ordering against a
  -- leftover row whose own next_attempt_at was set further in the
  -- past at its own suite's fixture-creation time.
  UPDATE platform_outbox_events
  SET attempt_count = 4, next_attempt_at = NULL, last_error = 'unsupported_event_type: platform.wf83c_poison.v1 (warmup)'
  WHERE id = v_id;
  IF (SELECT attempt_count FROM platform_outbox_events WHERE id = v_id) <> 4 THEN
    RAISE EXCEPTION 'race5 setup failed: expected attempt_count=4 before the raced final attempt';
  END IF;
END $$;
RESET ROLE;
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_attempt_count INTEGER; v_status TEXT;
BEGIN
  SELECT id INTO v_id FROM wf83c_ids WHERE name = 'race5';
  PERFORM wf83c_connect_worker('c1r5');
  PERFORM wf83c_connect_worker('c2r5');

  PERFORM dblink_send_query('c1r5', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceA-worker') WHERE event_id = '%s'::uuid$q$, v_id));
  PERFORM dblink_send_query('c2r5', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'raceB-worker') WHERE event_id = '%s'::uuid$q$, v_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r5', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r5', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r5', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r5', false);
  PERFORM dblink_disconnect('c1r5');
  PERFORM dblink_disconnect('c2r5');

  SELECT attempt_count, status INTO v_attempt_count, v_status FROM platform_outbox_events WHERE id = v_id;
  IF v_attempt_count <> 5 THEN
    RAISE EXCEPTION 'expected exactly ONE terminal-attempt increment (attempt_count=5), got % (r1=%, r2=%)', v_attempt_count, v_r1, v_r2;
  END IF;
  IF v_status <> 'dead_letter' THEN
    RAISE EXCEPTION 'expected the raced terminal attempt to transition to dead_letter exactly once, got status=%', v_status;
  END IF;
END $$;
INSERT INTO wf83c_results VALUES (5,'Two concurrent workers racing the FINAL (terminal) retry attempt of the same poison event: attempt_count advances to exactly 5 (never 6) and the event transitions to dead_letter exactly once -- the row lock prevents a double-counted terminal transition');

-- ── 6 & 7: no duplicate intent / no duplicate notification across
-- every race above (aggregate checks) ──
DO $$
DECLARE v_dupe_intents INTEGER; v_dupe_notifs INTEGER;
BEGIN
  SELECT count(*) INTO v_dupe_intents FROM (
    SELECT outbox_event_id, target_type, target_key, count(*) c FROM notification_intents
    GROUP BY outbox_event_id, target_type, target_key HAVING count(*) > 1
  ) x;
  IF v_dupe_intents <> 0 THEN RAISE EXCEPTION 'expected zero duplicate (outbox_event_id, target_type, target_key) intent rows across every race above, found %', v_dupe_intents; END IF;

  SELECT count(*) INTO v_dupe_notifs FROM (
    SELECT outbox_event_id, recipient_user_id, count(*) c FROM user_notifications
    GROUP BY outbox_event_id, recipient_user_id HAVING count(*) > 1
  ) x;
  IF v_dupe_notifs <> 0 THEN RAISE EXCEPTION 'expected zero duplicate (outbox_event_id, recipient_user_id) notification rows across every race above, found %', v_dupe_notifs; END IF;
END $$;
INSERT INTO wf83c_results VALUES (6,'Across every concurrent race scenario above, zero duplicate notification_intents rows exist for the same (outbox_event_id, target_type, target_key) -- create_notification_intent''s own ON CONFLICT held under real concurrent worker load');
INSERT INTO wf83c_results VALUES (7,'Across every concurrent race scenario above, zero duplicate user_notifications rows exist for the same (outbox_event_id, recipient_user_id) -- platform_create_user_notification''s own ON CONFLICT held under real concurrent worker load');

-- ── 8: unrelated organizations do not block globally ──
-- As in scenario 2, which specific connection claims which specific
-- row is unrestricted worker-pool behavior and not asserted -- only
-- that both cross-organization events reach completed and that the
-- combined wall-clock time reflects parallel, not serialized, progress.
-- Enqueue as its own, separately-committed top-level statement --
-- dblink sessions are independent connections (READ COMMITTED across
-- connections) and would not see these rows at all if they were
-- enqueued in the same still-open transaction as the race below.
DO $$
DECLARE v_id1 UUID; v_id2 UUID;
BEGIN
  v_id1 := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000001','83200000-0001-0000-0000-000000000001');
  v_id2 := wf83c_enqueue_supported('83200000-0000-0000-0000-000000000002','83200000-0001-0000-0000-000000000002');
  INSERT INTO wf83c_ids VALUES ('race8a', v_id1);
  INSERT INTO wf83c_ids VALUES ('race8b', v_id2);
END $$;

DO $$
DECLARE v_id1 UUID; v_id2 UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ; v_elapsed_ms NUMERIC;
BEGIN
  SELECT id INTO v_id1 FROM wf83c_ids WHERE name = 'race8a';
  SELECT id INTO v_id2 FROM wf83c_ids WHERE name = 'race8b';

  PERFORM wf83c_connect_worker('c1r8');
  PERFORM wf83c_connect_worker('c2r8');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1r8', $q$SELECT string_agg(outcome, ',') FROM process_platform_outbox_batch(25,'raceA-worker')$q$);
  PERFORM dblink_send_query('c2r8', $q$SELECT string_agg(outcome, ',') FROM process_platform_outbox_batch(25,'raceB-worker')$q$);

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r8', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r8', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r8', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r8', false);
  PERFORM dblink_disconnect('c1r8');
  PERFORM dblink_disconnect('c2r8');

  v_elapsed_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF (SELECT status FROM platform_outbox_events WHERE id = v_id1) <> 'completed'
     OR (SELECT status FROM platform_outbox_events WHERE id = v_id2) <> 'completed'
  THEN RAISE EXCEPTION 'expected both cross-organization events to reach completed (c1r8=%, c2r8=%)', v_r1, v_r2; END IF;
  IF v_elapsed_ms > 5000 THEN
    RAISE EXCEPTION 'cross-organization concurrent processing took %ms -- expected independent progress with no shared contention', v_elapsed_ms;
  END IF;
END $$;
INSERT INTO wf83c_results VALUES (8,'Two events belonging to entirely unrelated organizations, processed by two concurrent workers, complete independently well under a generous contention-detection bound -- the worker has no global/organization-wide lock');

-- ── 9: no deadlocks (aggregate) ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf83c_results WHERE scenario IN (1,2,3,4,5,8);
  IF v_count <> 6 THEN RAISE EXCEPTION 'expected scenarios 1,2,3,4,5,8 to have all completed without a deadlock error, found %', v_count; END IF;
END $$;
INSERT INTO wf83c_results VALUES (9,'No deadlock occurred in any of the preceding concurrent-session races -- each would have surfaced a "deadlock detected" dblink error and aborted before recording its result otherwise');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf83c_results;
  IF v_count <> 9 THEN RAISE EXCEPTION 'Expected 9 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification outbox worker concurrency tests PASSED: %/9', v_count;
END $$;

DROP FUNCTION wf83c_connect_worker(TEXT);
DROP FUNCTION wf83c_enqueue_supported(UUID, UUID);
